# Roadmap

Ordered by intent, not commitment. Items marked **(design ready)** have an
agreed approach; the rest are open.

## 1. Health & capacity overview in the PVE GUI — SHIPPED (experimental)

Landed as `api/FlashSystemAPI.pm` + the "FlashSystem" storage tab + the
Datacenter -> FlashSystem panel (`{storage}/overview`), see UPSTREAM.md
section 3. Still open within this item:

- **Field validation across firmwares**: the events/ports sections use
  whitelist extraction, so unknown field names degrade to empty sections —
  they need confirming per firmware (8.7 confirmed on 8.7.0.3; 9.x unknown).
- **The datacenter panel is not yet validated on hardware** — the storage tab
  is (8.7.0.3), the datacenter view has only unit coverage.
- **Event fetch cost**: the overview pulls the full unfixed event log (~1300
  rows on the validation array) per array on every panel load and Refresh, on
  top of pvestatd. A server-side `alert=yes` filter would cut it to a handful
  — confirm the REST spelling.
- **More sections once validated**: `lsenclosurebattery`, drive summary,
  reduction-savings figures, per-volume throttle visibility.
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
