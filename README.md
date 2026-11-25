# proxmox-flashsystem-plugin

A custom Proxmox VE storage plugin for **IBM Storage FlashSystem / IBM Storage
Virtualize**, driving the array's REST API (v1, port 7443) to provision **one
array volume per VM disk** — created, resized, snapshotted, migrated and
deleted from the Proxmox GUI, served to the nodes as raw block devices over
SCSI Fibre Channel (dm-multipath) or NVMe-oF (FC / TCP / RDMA).

This tree is a **local fork** of [olemyk/ibm-flashsystem-proxmox-plugin](https://github.com/olemyk/ibm-flashsystem-proxmox-plugin),
updated for Proxmox VE 9.2 and Storage Virtualize 9.1.3.1. What changed versus
upstream is in [LOCAL.md](LOCAL.md). Policy-based replication / HA scope is in
[PBR.md](PBR.md). Security findings are in [SECURITY.md](SECURITY.md).

Originally based on the plugin sample in IBM's *Storage Virtualize + Proxmox
VE* whitepaper, then extended and hardened in production. Every deviation from
the original sample exists because something broke without it; the details are
in [CHANGELOG.md](CHANGELOG.md) and the code comments.

## Status

Supported floor: **Storage Virtualize 9.1** and Proxmox VE 9.2. Proxmox VE
9.3 is tracked (storage API 17). New volumes are created with `mkvolume`
only. Firmware older than 9.1 is not a target.

| Component | Version |
|---|---|
| IBM Storage Virtualize firmware | 9.1 or newer (9.2.0 tracked, not hardware-validated) |
| Proxmox VE | 9.2, or 9.3 (schema dialog and guest volume types; not hardware-validated) |
| Transport | SCSI-FC (default), or NVMe-oF on FC / TCP / RDMA |
| Kubernetes | via proxmox-csi (`vm-9999-pvc-<uuid>` volumes) |

The SCSI-FC path was exercised in production on a 12-node PVE 9.2 cluster
before the floor moved to 9.1: on-demand provisioning, online resize, live
migration (multipath map handover — no data copy), move-disk, full clone,
array snapshots including RAM state, delete with array-side cleanup,
cloud-init disks, and Kubernetes CSI volumes.

**This fork** adds 9.1 JWT/403 handling, `mkvolume` + provisioning-policy
awareness, NVMe-oF (FC/TCP/RDMA), TLS CA pinning, `rename_volume`, and
volume-group placement. It also tracks Storage Virtualize 9.2.0 (LTS): no
replay of `expandvdisksize` after a lost response, `lsvolume` when a pool
field is `many`, and snapshot name/UUID for a partition management IP.
Those paths are unit-tested; they are **not** yet validated on a
FlashSystem 7600 / 9.1.3.1 or on 9.2.0. Use a scratch pool first.

On Proxmox VE 9.3 the Add menu builds the FlashSystem dialog from this
plugin's schema (`title`, advanced fields, hidden `fscreate`). The health
tab still comes from `gui/flashsystem-gui.js`. The Datacenter SAN view and
"snapshots as volume chains" belong to shared LVM, not to this plugin.

**Not supported:** templates / linked clones (no base-image support — keep
template VMs on LVM or dir storage; full clones *onto* this storage work),
snapshot-as-block-device. Cross-VM reassignment via `qm disk move --target-vmid`
now has a `rename_volume` implementation (`chvdisk -name`); VALIDATE it before
relying on it.

### What that validation does and does not cover

The table above covers the **storage plugin** — everything under "proven
operations" has run in production on a 12-node cluster. The reporting surfaces
added later have not all reached hardware, and it matters which is which,
because an unvalidated whitelist degrades to an empty section rather than an
error and can therefore look like a working panel with nothing in it.

| Surface | State |
|---|---|
| Storage plugin (provision, resize, migrate, clone, snapshot, delete) | SCSI-FC exercised in production before the 9.1 floor. 9.1 and 9.2 paths are unit-tested only |
| Health API + storage-view tab | Field names last checked on a FlashSystem 5200 / 8.7.0.3. Re-check on 9.1+ before trusting an empty section |
| Thin provisioning (`fsthin`) | Now `mkvolume -thin`. The earlier standard-pool check used the removed `mkvdisk -rsize` shape. Confirm `mkvolume -thin` on a 9.1 scratch pool |
| Thin provisioning on a **data reduction pool** | **Not validated.** DRPs apply their own rules to space-efficient volumes |
| Datacenter overview panel | **Unit coverage only** |
| Performance endpoint (`lsnodestats`, `lssystemstats`, `lsthrottle`, `-history`) | **Unit coverage only** |
| Per-volume consumption + `lssevdiskcopy` fill | **Unit coverage only** |
| Server-side `lseventlog` alert filter | **Unit coverage only** — falls back to the previous form if a firmware rejects it, and detects a firmware that ignores it |

Three specific unknowns the first hardware run is designed to settle, all
documented in `UPSTREAM.md` section 4: whether `lssystemstats` is reachable
over REST at all (it is absent from IBM's published OpenAPI schema for 8.7.0
and 9.1.3 while `/lsnodestats` is present, so a derived fallback ships either
way), which unit the `*_ms` statistics actually use, and whether the
`lseventlog` alert parameters are honoured or silently ignored.

## Layout

```
FlashSystemPlugin.pm            the storage plugin
gui/flashsystem-gui.js          Add/Edit dialogs, the health tab, the DC overview
gui/install-flashsystem-gui.sh  installs the GUI extension + APT re-apply hook
api/FlashSystemAPI.pm           read-only health & capacity API + array-wide overview
api/install-flashsystem-api.sh  registers the API into the PVE tree + APT re-apply hook
tests/                          unit tests — run anywhere perl exists, no array needed
```

## Requirements

**Array side** (manual, once):

- FC zoning between every node's HBAs and the array.
- A **host cluster** on the array containing every node of the PVE cluster —
  its name is the `fshostgroup` setting. Volumes are mapped to the host
  cluster once, which is what makes live migration a map handover.
- A REST user with the **Administrator** role. `Monitor` cannot write and
  `RestrictedAdmin` cannot `rmvdisk` — the latter fails only at delete time,
  so it looks fine for months. Scope the user to an ownership group if the
  array is shared.
- A storage pool (mdiskgrp) to allocate from. Start against a scratch pool.
- Storage Virtualize **9.1 or newer**. Snapshots use the Snapshot function
  (`addsnapshot`), not FlashCopy.

**Node side** (every node):

- `multipath.conf`: `user_friendly_names no` — the plugin resolves volumes as
  `/dev/mapper/3<vdisk_UID>`, which only exists when maps are WWID-named.
  (Explicitly aliased maps are unaffected; an alias always wins.)
- **LVM `global_filter` — required, not optional.** The plugin hands raw LUNs
  to guests; if a guest runs LVM, its volume groups appear in the *host's*
  `pvs`/`vgs`, and a mapped LUN that loses its paths makes `vgs` hang and
  takes down the node's management plane. Allow-list the devices the host
  itself needs and reject everything else, e.g.:

  ```
  global_filter=["a|^/dev/mapper/<your-host-devices>.*|","r|/dev/zd.*|","r|.*|"]
  ```

  Note that Proxmox upgrades rewrite this line — re-assert it after package
  changes (an APT Post-Invoke hook works well).
- Packages: `multipath-tools sg3-utils libwww-perl libjson-perl`.
- TCP 7443 open from the nodes to the array's management address.

**NVMe-oF extra (every node), when `fstransport` is `nvme-fc` / `nvme-tcp` / `nvme-rdma`:**

- `nvme-cli` installed; `nvme_core.multipath=Y` (native ANA). **Do not** use
  dm-multipath for NVMe/TCP — IBM requires native multipath there. Blacklist
  `NVME,IBM 2145` in `multipath.conf`.
- Host objects on the array must be protocol **NVMe** (`fcnvme` / `tcpnvme` /
  `rdmanvme`) and grouped in the `fshostgroup` host cluster. A volume cannot
  be mapped to SCSI and NVMe at the same time.
- NVMe/TCP or RDMA: set `fsnvmeaddr` to the array data IPs (port 4420 unless
  you change `fsnvmeport`). Persist discovery with `/etc/nvme/discovery.conf`
  + `nvmf-autoconnect.service` so reconnect survives reboot. On 9.2.0,
  NVMe/RDMA host attach may use jumbo frames (MTU 9000) on the host and the
  switch. The plugin does not set that.
- NVMe/FC: zone host WWPNs to the array's **NVMe** FC ports (not the SCSI
  ones). Some HBAs auto-connect; otherwise put `nn-0xWWNN:pn-0xWWPN` pairs in
  `fsnvmeaddr`.

## Install

```sh
# 1. the plugin (every node)
install -D -m 0644 FlashSystemPlugin.pm \
  /usr/share/perl5/PVE/Storage/Custom/FlashSystemPlugin.pm
perl -MPVE::Storage -e 'PVE::Storage::Plugin->lookup("flashsystem")' && echo OK
systemctl restart pvedaemon pvestatd pveproxy

# 2. the GUI dialogs (every node)
cd gui && ./install-flashsystem-gui.sh

# 3. the health API (every node) - REQUIRED by the GUI panels from step 2
cd ../api && ./install-flashsystem-api.sh
```

Two views, both read-only and both needing `Datastore.Audit` (or
`Datastore.Allocate`):

* **Storage view → FlashSystem** — one storage: array identity, pool capacity
  (physical and effective), volume counts, unfixed alerts, FC port state.
* **Datacenter → FlashSystem** — the whole array: every pool in use and which
  storages share each one, with prefix, thin/thick and volume counts; the
  largest volumes and a per-guest rollup, including the volumes in each pool
  this cluster does not manage; and array performance — front-end, back-end
  and drive IOPS, bandwidth and latency with five-minute peaks, per-canister
  CPU and cache, and configured throttles. One request per array per section,
  de-duplicated server-side.

Each section degrades independently if the array is slow, and a section that
fails omits its numbers rather than reporting zeros. CLI equivalents:

```sh
pvesh get /nodes/$(hostname)/flashsystem/<storage>/health
pvesh get /nodes/$(hostname)/flashsystem/<storage>/overview
pvesh get /nodes/$(hostname)/flashsystem/<storage>/performance
```

Two limits stated up front, because both are the array's rather than the
plugin's. **Per-volume performance does not exist** in the REST API — the
array's own GUI has no per-volume chart either, and the only source is the
`/dumps/iostats` XML, written once per `startstats` interval. **Per-volume
fill is not reported in data reduction pools**, where IBM documents the
`lssevdiskcopy` capacity fields as blank; the panel says so rather than
drawing an empty bar. See `UPSTREAM.md` section 4.

**After installing or updating the GUI extension, restart the browser as a
process.** A hard refresh, disable-cache and logout are all insufficient — VM
consoles open as popups that inherit the parent page's already-parsed JS, and
will show only a spinner until the browser restarts. This produces no error
anywhere and is very expensive to diagnose the first time.

## Storage configuration

Through the GUI (Datacenter → Storage → Add → IBM FlashSystem) or:

```sh
pvesm add flashsystem tier1 \
  --fsaddress <mgmt-ip> --fsuser <rest-user> \
  --fspool Pool0 --fshostgroup <host-cluster> \
  --fsprefix cl1tier1 --content images --shared 1
```

Put the REST password in `/etc/pve/priv/storage/<storeid>.pw` (root-only,
replicated cluster-wide by pmxcfs) rather than in `--fspassword`, which lands
in `storage.cfg` in clear text. The file's basename must equal the storage ID
exactly.

| Option | Fixed | Meaning |
|---|---|---|
| `fsaddress` | yes | array management IP/host |
| `fspool` | yes | mdiskgrp to allocate from |
| `fsprefix` | yes | **per-storage** array-object name prefix — see Naming |
| `fsuser` | no | REST username (Administrator role) |
| `fspassword` | no | REST password — prefer the `.pw` file |
| `fshostgroup` | no | host cluster on the array |
| `fsiogrp` | no | I/O group for new volumes (default `io_grp0`) |
| `fssnapshots` | no | enable array snapshots (Snapshot function; 9.1+) |
| `fsthin` | no | thin-provision **new** volumes (`mkvolume -thin`). Ignored when the pool already has a provisioning policy. |
| `fstransport` | yes | `scsi-fc` (default), `nvme-fc`, `nvme-tcp`, `nvme-rdma` |
| `fsnvmeaddr` | no | NVMe-oF discovery addresses (comma-separated). TCP/RDMA: IPs. FC: `nn-0xWWNN:pn-0xWWPN`. |
| `fsnvmeport` | no | NVMe/TCP or NVMe/RDMA port (default `4420`) |
| `fsnvmesubnqn` | no | optional subsystem NQN; empty = `nvme connect-all` discovers it |
| `fsvolumegroup` | no | existing array volume group for new volumes (PBR/PBHA awareness) |
| `fscafile` | no | PEM CA bundle for the management endpoint. Unset = verify against the host trust store. |
| `fsinsecure` | no | disable TLS certificate verification (self-signed lab arrays only; logs a one-time warning) |

The standard PVE storage options `content`, `shared`, `nodes` and `disable`
are accepted as usual; set `--shared 1` (host-cluster-mapped volumes are
inherently shared — without it, migration copies disks instead of handing
over the multipath map).

### Naming and the 63-character budget

Array volume names are **global across all pools** on one system. The plugin
therefore namespaces every object with the storage's `fsprefix`
(`<prefix>-vm-<vmid>-disk-<N>`), and `list_images`/`free_image` refuse to see
or touch anything outside their own prefix. Rules that follow:

- **One prefix per storage, never shared** — even across pools. Two storages
  sharing a prefix collide on the first move-disk between them
  (`CMMVC6035E`) and can see and delete each other's volumes.
- Array object names cap at **63 characters**, shared by
  `prefix + '-' + volname + '.' + snapshot-name`. The longest *common*
  volname is Kubernetes CSI's `vm-9999-pvc-<uuid>` at 48 chars — so keep
  prefixes ≤ 14 chars, and much shorter on storages that need both CSI
  volumes and snapshots (state volumes with long snapshot names can exceed
  48). The plugin refuses oversize creations with an actionable error
  instead of an opaque CMMVC.
- PVE-side volume names stay canonical (`vm-<vmid>-…`); the prefix exists
  only on the array.

### Thin provisioning (`fsthin`)

New volumes are created with **`mkvolume`**. Bare create without `fsthin`
is fully allocated. `fsthin 1` adds `mkvolume -thin`. When the pool already
has a provisioning policy, `-thin` is omitted — the policy wins. A
`storage.cfg` line `fscreate mkvolume` is ignored. Any other `fscreate`
value is rejected; delete the line.

`mkvolume -thin` is not yet hardware-validated on 9.1. **Not yet validated
on a data reduction pool** — DRPs apply their own rules to space-efficient
volumes, so test on a scratch pool first.

Thin means **overcommit**: a pool driven to physical-full takes every volume
in it offline. Have array-side physical-free alerting in place before
enabling it on pools shared with other workloads. Existing volumes keep their
allocation; convert online array-side with `addvdiskcopy -autodelete`.

## Operational behavior worth knowing

- **Capacity is reported as physical, not effective.** On data reduction
  pools `lsmdiskgrp` reports effective capacity (physical × assumed
  compression); provisioning against that number can drive a shared pool to
  physical-full. `status()` prefers `physical_capacity`/`physical_free_capacity`
  when present, so the PVE usage bar matches the array GUI's "Usable" figures.
- **REST throttling is handled.** The array rate-limits its API (HTTP 429);
  the plugin retries that with backoff (honoring sane `Retry-After`). A lost
  response on `expandvdisksize`, `mkvolume`, `rmvdisk`, or a snapshot
  command is **not** retried: those commands can commit before the HTTP
  client sees the failure, and a second `expandvdisksize` grows the volume
  again. Reads still retry transport errors. Pool status is cached
  per (array, pool) within each pvestatd cycle, so storages
  sharing a pool cost one query and a down array is probed once per cycle,
  not once per storage. `status()` is also hard-bounded — a slow array
  reports inactive instead of stalling pvestatd. The datacenter overview
  de-duplicates for the same reason: it is a human-triggered burst against
  the same limiter, so array facts and each pool are fetched once per
  request rather than once per storage.
- **Volume protection windows are surfaced, not hidden.** Deleting or
  unmapping a recently written volume fails with `CMMVC8478E`/`CMMVC8957E`
  until the array's protection period passes. The plugin fails loudly on
  purpose (tolerating it would orphan volumes); automation should treat these
  as retryable, and humans should just wait. Do not disable volume protection
  to avoid the wait.
- **Snapshots** use the Snapshot function (`addsnapshot`), not FlashCopy.
  9.2 is the last release that still includes legacy FlashCopy. Loose-volume
  rollback/delete send a snapshot UUID when the array returns one, otherwise
  the numeric snapshot id (a bare name draws `CMMVC5707E`). The
  volume is named, not passed as a short id, so a partition management IP
  can accept the call. A volume that already belongs to a volume group is
  not snapshotted by snapshotting that whole group. A RAM-state snapshot
  creates an extra volume sized to guest RAM in the same pool.
  Re-activation mapping conflicts (`CMMVC9066E`) are treated as success.
- **List commands take `-bytes`** (JSON `true`), not `-unit` — `-unit b`
  belongs to `mkvolume`/`expandvdisksize` only, and `expandvdisksize` takes
  the **delta**, not an absolute size.

## Testing

```sh
tests/run.sh
```

Syntax-checks the module against stubbed PVE modules and runs the unit
suites (`t_prefix.pl`, `t_status.pl`, `t_names.pl`, `t_api.pl`): prefix
translation and cross-tenant isolation, capacity preference
(physical vs effective, with real `lsmdiskgrp -bytes` fixtures), the volume
name grammar and 63-char gate (including verified regex-bypass regressions:
trailing newlines, Unicode digit/word lookalikes), status caching, and the
thin-provisioning parameter shape, the API's registered surface and view
helpers, and the overview's degradation behaviour (a failed section must omit
its fields, never report zeros). No array needed.

## Security notes

- **TLS verification is on** for the management endpoint. A private CA is
  pinned with `fscafile`. A self-signed lab array sets `fsinsecure=1` (one
  warning). Certificate failures are not retried. See `SECURITY.md`.
- The REST user can do anything its role allows on the array — the plugin's
  prefix discipline is enforcement in code, not in the account. Use ownership
  groups where tenancy matters.

## Open questions (for IBM collaboration)

1. **DRP deprecation**: with data reduction pools being phased out, what
   allocation guidance should new 9.1+ deployments follow? Create is
   `mkvolume` only.
2. **9.1 / 9.2 capacity fields**: which `lsmdiskgrp` fields should
   `status()` prefer, and do the `physical_*` fields survive on 9.2?
3. **REST on 9.1 and 9.2**: documented rate limits, token lifetimes,
   batching, or keep-alive guidance we should adopt instead of the current
   empirical backoff?
4. **Object-name limits**: is 63 chars the documented cap for volume and
   snapshot names on all current platforms?
5. **Licensing of the derived sample**: this plugin started from the sample
   code in the *Storage Virtualize + Proxmox VE* whitepaper (see
   `UPSTREAM.md`). Under what terms was that sample published, and what does
   that allow for the licence of this derived work?
6. **`lssystemstats` over REST**: it is documented in the CLI reference but
   absent from the published REST OpenAPI schema for both 8.7.0 and 9.1.3,
   while `/lsnodestats` is present. Is it reachable, and is its absence from
   the schema intentional?
7. **The `*_ms` unit**: the 8.7 `stat_name` descriptions say microseconds, the
   attribute table reads as milliseconds, and the Performance statistics page
   says the CLI always displays microseconds. Which is authoritative? The
   panel currently renders these values unlabelled rather than guess.

## License

To be decided before publication — until a LICENSE file exists, all rights
reserved.
