# Changelog

Pre-release history, condensed from internal deployment tags. Dates are when
the change reached a 12-node production cluster (PVE 9.2, firmware 8.7).

## Unreleased — 2026-08-31

- **Resize verifies the host device instead of assuming it.**
  `expandvdisksize` returns before the array commits the new capacity to a
  host `READ CAPACITY`, so a single immediate rescan races it and loses —
  seen live on a 20G→50G production resize where all 8 paths still read the
  old size, the plugin returned success, and QEMU failed the guest-side grow
  with `Cannot grow device files`. Now polls to the requested size and dies
  naming the array size, the device size, every path size and the recovery.
  Background formatting is not the blocker: a manual rescan succeeded while
  the array was still formatting at 44%.
- **The failure message says DO NOT re-run the resize**, because PVE sizes
  from `volume_size_info` (answered from the array, already grown) and the
  GUI only sends increments — so retrying expands the volume a second time,
  permanently. `activate_volume` now re-syncs capacity best-effort, making
  stop/start or migrate the supported recovery; previously no operator
  gesture reached host propagation at all.
- `_dm_node` no longer assumes `/dev/mapper/<wwid>` is a symlink (it is a
  real device node without udev), validates the result, falls back to
  `/sys/block/dm-*/dm/name`, and fails immediately rather than after the
  full settle budget. The dm node is re-resolved each iteration, so a map
  reassembled underneath the loop cannot make it check the wrong device.
- One `lsvdisk` per resize instead of two.
- `$MAPPER_DIR` and `$RESIZE_SETTLE_TIMEOUT` are documented test seams:
  the settle loop now runs against a fixture, and swapping
  `_resize_host_device`'s parameters produces 10 test failures where the
  previous tests stayed green.

## Unreleased — 2026-08-26

- **Performance endpoint + Datacenter performance section**:
  `GET /nodes/{node}/flashsystem/{storage}/performance` returns front-end,
  back-end and drive IOPS/bandwidth/latency with five-minute peaks,
  per-canister CPU/cache/latency, configured throttles, and a short
  front-end history for sparklines. `lsnodestats` is the primary source —
  `lssystemstats` is absent from IBM's published REST schema for both 8.7.0
  and 9.1.3, so when it is unreachable the same view is derived from the
  per-node rows (throughput summed, latency and percentages from the worst
  canister, flagged `derived`). Separate endpoint on its own deadline so a
  slow statistics call cannot starve the capacity view. Latency is rendered
  **without a unit**: IBM's 8.7 docs contradict themselves on whether the
  `*_ms` statistics are microseconds or milliseconds, and guessing is a
  1000x error.
- **Ranked consumption** in both `overview` (per pool) and `health` (per
  storage): largest volumes, per-guest rollup, and the volumes in the pool
  this cluster does not manage — computed from the concise `lsvdisk` rows
  those sections already fetch, so no extra array traffic. The GUI joins
  VMIDs to VM names from the resource store, and columns are click-sortable.
- **Per-volume fill in one call**: `lssevdiskcopy` per pool replaces any
  per-volume fan-out, which matters because the array runs one CLI command
  at a time cluster-wide behind a 10 req/s cap. The denominator follows
  `autoexpand` — with it off, 100% of `real_capacity` takes the volume
  offline. Skipped entirely on data reduction pools, where IBM documents
  these fields as blank; the panel says so rather than drawing an empty bar.
- **Cheaper alerts**: `lseventlog` now sends `alert=yes message=no
  monitoring=no fixed=no` rather than fetching the whole unfixed log, with a
  fallback when a firmware rejects the parameters and an arithmetic
  self-check for one that silently ignores them.
- `fast_write_state=corrupt` surfaced beside offline volumes — it needs
  `recovervdisk`, and a size ranking is the wrong place to learn that.
  Attention rows render first and unranked, so a small offline volume in a
  pool of large ones cannot hide below the top ten.
- **Three buckets on the storage tab**: a sibling flashsystem storage sharing
  the pool is counted separately from another tenant. Folding siblings into
  "foreign" made a tier storage attribute its own cluster's Kubernetes PVCs to
  the VMware volumes next door.
- **Theme-safe styling**: one injected stylesheet replaces ~100 inline style
  attributes. The previous inline colours were broken under one theme or the
  other — the datacenter panel assumed dark, the health panel assumed light.
  Text is now `currentColor` plus `opacity` and lines are neutral rgba greys,
  so no theme detection is needed; only four semantic hues are absolute, and
  a test asserts nothing else creeps back. Performance renders as a tile grid
  with sparklines, and peaks print the time alone since they cover the last
  five minutes.
- **GUI render tests** (`tests/t_gui.js`, stubbed ExtJS, skipped without node):
  two defects found in review were renderer-only — data the API computed,
  returned and unit-tested that nothing ever displayed — which no Perl test
  can see.

- **Health & capacity API + "FlashSystem" storage tab** (experimental):
  `PVE::API2::FlashSystem` exposes read-only
  `GET /nodes/{node}/flashsystem/{storage}/health` — system identity, pool
  capacity (physical and effective), volume counts, unfixed events, FC port
  state — registered into the API tree by a verified, marker-wrapped patch
  to `PVE/API2/Nodes.pm` with an APT re-apply hook. The GUI tab mounts via a
  guarded `PVE.panel.Config` override. Sections are eval-guarded and
  time-bounded. Validated on a FlashSystem 5200 running 8.7.0.3 — all
  whitelisted field names matched. Events are split into alerts (non-zero
  error code) and total unfixed: the raw `fixed=no` count is dominated by
  informational chatter (1317 events on the validation array, one of them
  actionable), which would otherwise bury a real pool-space warning.
- **Datacenter overview**: a "FlashSystem" entry in the Datacenter menu
  beside Ceph, served by `GET /nodes/{node}/flashsystem/{storage}/overview` —
  every pool on the array and which storages share each one, with prefix,
  thin/thick and volume counts. De-duplicated server-side: array facts once,
  each pool once, so an 8-storage / 4-pool cluster costs 11 REST calls instead
  of 40 and the panel makes one request per array. `index` gained `address`
  for grouping. Peers are permission-filtered, and failed sections omit their
  fields rather than reporting zeros.
- **Thin provisioning** (`fsthin`): opt-in `mkvdisk -rsize 2% -autoexpand
  -warning 80%` for new volumes, with a matching GUI checkbox. Off by
  default; bare mkvdisk volumes are fully allocated (confirmed via
  `lsvdisk` `capacity` == `real_capacity`), which also bypasses DRP
  thin/dedup. Validated on a standard pool (5200 / 8.7.0.3): 100 GiB
  presented, 5 GiB real, autoexpand growing on write. Data reduction pools
  remain untested for this path.
- First public packaging: de-branded headers, documentation-range IPs in
  test fixtures, dual-home test harness (runs from this repo layout and
  from a vendored `files/` layout unchanged).

## 2026-08-18

- **Retry HTTP 429** from the array's REST throttling (Retry-After honored
  when 1–10s, else 1/2/4s backoff). Found live: pvestatd polling 9 storages
  (8 production + a trial storage) from 12 nodes is ~11 req/s
  steady state; a template import on top drew `mkvdisk failed: 429`.
- **Per-cycle status cache**: `status()` caches `lsmdiskgrp` per
  (array, pool) in pvestatd's cycle cache — storages sharing a pool cost one
  REST call, and a down array is probed once per cycle, not once per storage.
  Failures are cached too.

## 2026-08-17

- **Volume-name grammar widened** to everything PVE and its ecosystem
  actually generate: `disk-N`, `state-*`, `cloudinit`, `fleece-N`, and
  Kubernetes CSI `pvc-<uuid>`. The original enumeration lived in three
  places (alloc, parse, list) and rejected all but the first two — a CSI
  volume would have been uncreatable, unattachable, and invisible.
- **63-char array-name gate** at allocation, with an actionable error
  (prefix + volname budget) instead of an opaque CMMVC failure. The CSI name
  shape (48 chars) makes the budget real.
- **Regex hardening** after adversarial review, with regression tests:
  `\z` anchors (plain `$` accepts a trailing newline), `/a` flag (bare
  `\w`/`\d` match Unicode lookalikes in UTF-8-flagged JSON strings —
  fullwidth digits passed `\d`).

## 2026-08-13

- **Per-storage prefixes** after a live `CMMVC6035E`: array volume names are
  global across pools, so a prefix shared by two storages collides on the
  first move-disk between them. Prefix isolation (list/delete refuse foreign
  objects) is unit-tested, including near-miss prefixes.
- **Physical capacity preferred** in `status()` on data reduction pools:
  effective capacity (physical × assumed compression) invited provisioning a
  shared pool to physical-full, which takes every volume in it offline.
  Observed gap at the time: 44 TiB "free" effective vs 4 TiB physical.

## 2026-08-12 — initial production deployment

- Fleet rollout of the whitepaper-derived plugin with fixes discovered en
  route: `-bytes` (not `-unit`) on list commands (`CMMVC5709E`), snapshot
  remove/restore by `-snapshotid` (`CMMVC5707E`), idempotent host-cluster
  mapping (`CMMVC9066E` tolerated), storeid-keyed password file resolution,
  stale-SCSI cleanup on cross-node reattach (`rescan-scsi-bus.sh`),
  host-side resize propagation, full-clone support, and GUI Add/Edit
  dialogs (pve-manager has no frontend plugin API; the installer appends a
  marker-wrapped snippet and an APT hook re-applies it after upgrades).
- Operational hard requirement documented: host LVM `global_filter`
  (allow-list + reject-all) — without it, guest LVM appears on the host and
  a pathless LUN hangs `vgs`/pvestatd and takes down the node's management
  plane.
