# Provenance and deviations

This plugin started from the sample code in IBM's *Storage Virtualize +
Proxmox VE* whitepaper. Code comments reading `LOCAL PATCH (see UPSTREAM.md)`
point here: each numbered section below documents one deliberate deviation
from the whitepaper sample, why it exists, and what proved it. Dates are
production deployments (firmware 8.7, PVE 9.2, 12-node FC/multipath cluster).

## 1. `fsprefix` — per-storage namespacing of array objects

The sample names array volumes after the PVE volume verbatim
(`vm-124-disk-0`). Array volume names are **global across all pools** on one
system, so any two storages — same cluster or different clusters — sharing an
array collide the moment both hold a VM with the same VMID: identical object
names, mutual visibility in `list_images`, and the ability to delete each
other's disks through an ordinary `free_image`.

The `fsprefix` option (fixed at creation, one prefix per storage, never
shared) namespaces every object as `<prefix>-vm-<vmid>-…`. Two helpers do the
translation at the array boundary; `_volname_from_array` returns undef for
foreign objects, which is what keeps one storage's disks out of another's
listing. PVE-side volume names stay canonical — PVE core validates them in
`find_free_diskname`, migration and backup, so the prefix exists only on the
array. With no prefix configured both helpers are pass-throughs (sample
behavior unchanged).

Proven the hard way on 2026-08-13: a cluster-wide (rather than per-storage)
prefix collided with itself on the first move-disk between two of its own
storages — `CMMVC6035E The action failed as the object already exists`.
Unit tests cover both directions, round-trips, cross-tenant isolation and
near-miss prefixes (`tests/t_prefix.pl`).

## 1b. Physical capacity preferred in `status()`

On data reduction pools `lsmdiskgrp` reports `capacity`/`free_capacity` in
*effective* terms — physical × an assumed compression ratio for the
self-compressing drives. Observed live: a pool showing 44 TiB "free"
effective with 4.1 TiB physically left. A DRP driven to physical-full takes
**every volume in it offline**, and the PVE capacity bar is what people
provision against — so `_pool_usage()` prefers
`physical_capacity`/`physical_free_capacity` when present. Standard pools
carry no `physical_*` fields and keep sample behavior. Fixture-tested with
real `lsmdiskgrp -bytes` output (`tests/t_status.pl`).

## 1c. One volume-name grammar + the 63-character gate

The sample's name validation enumerated `disk-N` and `state-*` in three
separate regexes (`parse_volname`, `alloc_image`, `list_images`) — rejecting
names PVE itself generates (`vm-<id>-cloudinit`, `vm-<id>-fleece-N`) and
Kubernetes CSI's `vm-9999-pvc-<uuid>`. A CSI volume was uncreatable; had it
been created, it would also have been unattachable and invisible.

Replaced with one shared `$VOLNAME_SUFFIX` grammar. The generic arm is
deliberately dot-free so an array snapshot object (`<volname>.<snap>`) can
never round-trip through `list_images` as a phantom volume; only the
`state-` arm keeps dots (sample charset). All three matches are
`\z`-anchored and `/a`-flagged: names arrive from `decode_json` as possibly
UTF-8-flagged strings, where a plain `$` accepts a trailing newline and bare
`\w`/`\d` match Unicode lookalikes (fullwidth digits pass `\d`) — all three
bypasses were demonstrated live in adversarial review and are pinned as
regression tests (`tests/t_names.pl`).

`alloc_image` additionally enforces the Storage Virtualize 63-character
object-name cap with an actionable error (prefix + volname budget) instead of
letting `mkvdisk` fail with an opaque CMMVC. The budget is real: a 14-char
prefix plus the 48-char CSI name shape is exactly 63.

## 1d. 429 retry + per-cycle status cache

The array throttles its REST API. Steady-state load is real — pvestatd polls
every flashsystem storage from every node (~11 req/s with 9 storages ×
12 nodes) — and a provisioning burst on top drew
`mkvdisk failed: 429 Too Many Requests` live on 2026-08-18. `_cmd` retries
429 up to three times (Retry-After honored when 1–10s, else 1/2/4s backoff;
under `status()`'s 10s alarm a sleeping retry is interrupted and reported as
inactive, as intended). `status()` caches the `lsmdiskgrp` result per
(array, pool) in pvestatd's per-cycle cache — storages sharing a pool cost
one REST call per cycle, and a down array is probed once, not once per
storage. Cache-hit and cached-failure paths are unit-tested by seeding the
cache (`tests/t_status.pl`).

## 1e. Optional thin provisioning (`fsthin`)

Bare `mkvdisk` creates FULLY ALLOCATED volumes — confirmed live 2026-08-25
via `lsvdisk` (`capacity` == `real_capacity`) — which reserves the full
provisioned size and bypasses a DRP's thin/dedup layer. `fsthin 1` adds
`-rsize 2% -autoexpand -warning 80%`; chosen over the newer `mkvolume`
because rsize-thin is the mechanism that exists on standard pools too, which
matters as IBM moves away from DRPs. Affects NEW volumes only; existing
volumes convert online array-side via `addvdiskcopy -autodelete`.

**Validated 2026-08-26** on a **standard pool** (FlashSystem 5200, firmware
8.7.0.3): `mkvdisk` accepted `rsize` as `'2%'`, `autoexpand` as a JSON
boolean and `warning` as `'80%'`. A 100 GiB volume was created with 5 GiB
real capacity, reported by the array as *Capacity savings: Thin-provisioned*
at an 80% warning threshold, and real capacity grew ahead of the data as it
was written — autoexpand confirmed working.

**Not yet validated on a data reduction pool.** DRPs apply their own rules
to space-efficient volumes; test on a scratch DRP before enabling `fsthin`
on one. (IBM state they are moving away from DRPs, so the standard-pool path
is the strategically relevant one.)

**Thin means overcommit.** Have array-side physical-free alerting in place
before enabling on any pool shared with other workloads — a pool driven to
physical-full takes every volume in it offline.

## 2. GUI Add/Edit dialogs

pve-manager has no frontend plugin API, so a custom storage type never
appears in the Add menu. `gui/flashsystem-gui.js` defines the input panel and
registers the type in `PVE.Utils.storageSchema`; the installer appends it to
`pvemanagerlib.js` inside marker comments and installs an APT Post-Invoke
hook that re-applies it after pve-manager upgrades rewrite that file.
Form fixes learned in production: a required Prefix field (create-only —
`fsprefix` is fixed and a storage created without one can never gain one),
`shared=1` defaulted on create (host-cluster-mapped volumes are inherently
shared; without it migration copies disks), the content selector restricted
to what a raw-block plugin can hold, and the Thin provision checkbox (1e).

After installing or updating the GUI extension, **restart the browser as a
process** — consoles open as popups that inherit the parent page's parsed JS
and show only a spinner until the browser restarts. No error appears
anywhere; this is very expensive to diagnose the first time.

## 3. Health & capacity API + "FlashSystem" storage tab

`api/FlashSystemAPI.pm` (`PVE::API2::FlashSystem`) exposes read-only

```
GET /nodes/{node}/flashsystem                      -> flashsystem storages
GET /nodes/{node}/flashsystem/{storage}/health     -> aggregate
```

— system identity, pool capacity (physical AND effective, same preference as
1b), volume counts (this storage vs the whole pool), unfixed events, FC port
state. Every array read goes through the plugin's `_cmd` (429 retry, token
cache), one bounded, eval-guarded call per section: a slow or unreachable
array yields partial data with per-section errors, never a hung API worker.
The health method is `protected` because resolving the REST credential reads
root-only `/etc/pve/priv/storage/<id>.pw`.

Proxmox has no API plugin registry, so `api/install-flashsystem-api.sh`
appends a marker-wrapped registration block to `PVE/API2/Nodes.pm` (executed
at module load), verifies `PVE::API2::Nodes` still loads — restoring the
original file if not — and installs an APT hook that re-applies the block
after pve-manager upgrades. The same mechanism the GUI extension uses.

The GUI side (in `gui/flashsystem-gui.js`) mounts a "FlashSystem" tab on the
storage view by overriding `PVE.panel.Config.initComponent` — the storage
browser assembles its tab items before Config consumes them, so the override
can add one without re-implementing the browser. Guarded so ExtJS-internals
drift in a future pve-manager degrades to "no tab", never a broken storage
view. Requires `Datastore.Audit` or `Datastore.Allocate` on the storage.

**Validated 2026-08-26** against an **IBM FlashSystem 5200, firmware
8.7.0.3**: all five sections returned content and every whitelisted field
name matched (`lssystem`: name/code_level/product_name/topology;
`lsmdiskgrp -bytes` incl. `physical_*` on a *standard* pool, where physical
equals effective and the preference is a correct no-op; `lsportfc`:
id/fc_io_port_id/status/port_speed/attachment/node_name; `lseventlog`:
sequence_number/error_code/description/object_type/object_name/last_timestamp).

That run also produced a design fix: `fixed=no` returns the array's
**informational** log as well as alerts — 1317 unfixed events, of which
exactly one (`1867 Data reduction pool space warning`) was actionable. The
view therefore splits `alerts` (events carrying a non-zero error code) from
`unfixed_total`, and lists only alerts; the panel shows a green check when
`alerts` is zero. `lseventlog` is a **system** log, so these are array-wide
— every storage on one array reports the same alerts.

**Still VALIDATE on other firmwares**: field names may differ (unknown
fields degrade to omissions, so a mismatch shows an empty section, never an
error). A server-side `alert=yes` filter would shrink the fetch from ~1300
rows to a handful — worth confirming the REST spelling; the client-side
split stays either way.
