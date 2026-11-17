# Roadmap

Ordered by intent, not commitment. Items marked **(design ready)** have an
agreed approach; the rest are open.

## 1. Health & capacity overview in the PVE GUI — SHIPPED (experimental)

Landed as `api/FlashSystemAPI.pm` + the "FlashSystem" storage tab + the
Datacenter -> FlashSystem panel (`{storage}/overview`), see UPSTREAM.md
section 3. Still open within this item:

- **Field validation across firmwares**: the events/ports/statistics sections
  use whitelist extraction, so unknown field names degrade to empty sections —
  they need confirming on 9.1 and 9.2. The last hardware check of the
  whitelist was 8.7.0.3, before the support floor moved. `iser_io`/`iser_mb`
  were **removed** at 9.1.0, so a 9.1+ plugin must not require them. Treat
  the statistic list as a set to intersect at runtime, never a fixed schema.
- **Not yet validated on hardware**: the datacenter panel as a whole, the
  performance endpoint, and per-volume fill. The storage tab's original
  sections are validated (8.7.0.3); everything added since has unit coverage
  only.
- **Three specific probes** the first hardware run should settle:
  (1) is `lssystemstats` reachable over REST v1 on this array — check
  `https://<array>:7443/rest/explorer/`; the derived fallback ships either
  way. (2) the `*_ms` unit — compare `vdisk_ms` against the array GUI's
  latency chart at the same moment. (3) does the `lseventlog` alert filter
  actually apply, or is it silently ignored (the code detects the latter, but
  confirm which path ran).
- **Mirrored / HA volumes**: `lsvdisk` filtered on `mdisk_grp_name` misses
  rows whose pool is `many`. The health and overview lists now append
  `lsvolume` rows (9.2, `local_pool_name`) that `lsvdisk` did not return.
  Still needs a hardware check. Pre-9.2 arrays have no `lsvolume`, so
  mirrored volumes there are still missed.
- **Per-volume fill in data reduction pools**: `lssevdiskcopy` is still
  skipped (those fields are blank). On 9.2 the same pool list's `lsvolume`
  `physical_used` is drawn against provisioned size. Arrays without
  `physical_used` keep the "fill unavailable" note. Not hardware-validated.
- **More sections once validated**: `lsenclosurebattery`, drive summary,
  reduction-savings figures, `lsvdiskprogress` / `lsvdisksyncprogress` (a
  volume actively formatting or resyncing explains latency), `lsmdisk`
  `path_count` vs `max_path_count` (a lost path to one FC switch), and
  `lsarray` `raid_status`.
- **Per-volume performance, if it is ever wanted**: only the
  `/dumps/iostats` XML carries it — `lsdumps` + `download`, plus `cpdumps`
  for the non-config canister. Cumulative counters needing a two-sample
  diff, written once per `startstats` interval (default 5 min), ~80 minutes
  of retention. Ship it opt-in with the sample timestamp beside every number,
  or not at all. Reading only the config node silently under-reports every
  volume driven through both canisters.
- **Complementary path**: a small Prometheus exporter for shops that already
  run Grafana — the PVE panel is at-a-glance state, Grafana is history and
  alerting. Shares the metric list with the API module.

## 2. Thin provisioning refinements

`fsthin` sends `mkvolume -thin` and is omitted when the pool has a
provisioning policy. The pre-9.1 `mkvdisk -rsize` shape is removed. Open:
confirm `mkvolume -thin` on a 9.1 scratch pool, and document a tested
online thick→thin conversion (`addvdiskcopy -autodelete`).

## 3. Firmware 9.x capacity fields

`_pool_usage()` prefers `physical_*` and falls back to `usable_*` when
physical is absent. That is fixture-tested, not confirmed against a 9.2
`lsmdiskgrp -bytes`. A real fixture replaces the guess. Snapshot-buffer
capacity is not subtracted on its own; if 9.2 already folds it into
`physical_free_capacity`, no further change is required.

## 4. TLS CA pinning (`fscafile`)

Replace `verify_hostname => 0` with an optional CA bundle path option;
verification on by default when the option is set.

## 5. `rename_volume` support

`chvdisk -name` makes array-side rename trivial; implementing
`rename_volume` enables clean `qm disk move --target-vmid` reassignment
(today: attach-by-volid). Prerequisite for tidy rebuild-OS-keep-data flows.

## 6. Base image / template support (maybe)

`create_base` via array-side rename plus grammar support for `base-*` names
would allow `qm template` on this storage. Deliberately deferred: full clones
work, and COW-less "templates" are just renamed volumes — the value is
convenience, the cost is a wider grammar and more state to reason about.

## 7. Rate-limit tuning from documented numbers

The 429 backoff (1/2/4s, Retry-After honored) is empirical. If IBM documents
the actual limits per firmware (README open question 3), tune to them.
