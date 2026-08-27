# Roadmap

Ordered by intent, not commitment. Items marked **(design ready)** have an
agreed approach; the rest are open.

## 1. Health & capacity overview in the PVE GUI — SHIPPED (experimental)

Landed as `api/FlashSystemAPI.pm` + the "FlashSystem" storage tab + the
Datacenter -> FlashSystem panel (`{storage}/overview`), see UPSTREAM.md
section 3. Still open within this item:

- **Field validation across firmwares**: the events/ports/statistics sections
  use whitelist extraction, so unknown field names degrade to empty sections —
  they need confirming per firmware (8.7 confirmed on 8.7.0.3; 9.x unknown).
  Note `iser_io`/`iser_mb` exist at 8.7.0 and are **removed** at 9.1.0, and
  `nvme_*` are absent before 8.4 — treat the statistic list as a set to
  intersect at runtime, never a fixed schema.
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
- **Mirrored volumes are missed**: `lsvdisk` is filtered server-side on
  `mdisk_grp_name`, which reports `many` for mirrored volumes, so they fall
  out of pool counts and rankings. The fix is an unfiltered fetch scoped
  client-side on `parent_mdisk_grp_name`; it changes production-validated
  counting behaviour, so it wants its own change and its own validation.
- **Per-volume fill in data reduction pools**: IBM reports the
  `lssevdiskcopy` capacity fields as blank in a DRP, and the only documented
  alternative — `used_capacity_before_reduction` — is detailed-view only,
  i.e. one serialised call per volume. Worth offering as an explicit
  on-demand drill-down for a single volume; never as part of the always-on
  view. This matters wherever every tier is a DRP, which was the case
  on the cluster this was validated against.
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

`fsthin` ships (mkvdisk `-rsize 2% -autoexpand -warning 80%`). Open:
whether `mkvolume` semantics are preferable once IBM's post-DRP guidance is
clear, and whether rsize/warning deserve per-storage knobs. Also: document a
tested online thick→thin conversion procedure (`addvdiskcopy -autodelete`).

## 3. Firmware 9.x capacity fields

Adapt `_pool_usage()` to whatever 9.x reports (see README open question 2).
The function is deliberately tiny and fixture-tested — new firmware means new
fixtures from a real `lsmdiskgrp -bytes`, then the preference logic.

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
