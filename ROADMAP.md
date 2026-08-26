# Roadmap

Ordered by intent, not commitment. Items marked **(design ready)** have an
agreed approach; the rest are open.

## 1. Health & capacity overview in the PVE GUI (design ready)

A Ceph-style panel: array health, per-pool physical/effective capacity and
reduction savings, volume counts vs limits, unfixed events, FC port and
enclosure state — visible from Proxmox without opening the array GUI.

Proxmox has no plugin API for either REST endpoints or GUI panels, but this
project already patches `pvemanagerlib.js` with marker-wrapped blocks and an
APT re-apply hook. The same technique extends to the API side:

- **API bridge**: a `PVE::API2::FlashSystem` module installed next to the
  plugin, exposing read-only endpoints such as
  `GET /nodes/{node}/flashsystem/{storage}/health`, registered by patching
  the API index the same marker+hook way. All array reads go through the
  plugin's existing `_cmd` path (429 retry, bounded timeouts, per-cycle
  caching) — the pvestatd lessons apply doubly to a dashboard.
  Data sources: `lssystem` (health, code level), `lsmdiskgrp -bytes`
  (physical + effective + savings), `lsvdisk` counts, `lseventlog` with
  `alert=yes` / unfixed, `lsportfc`, `lsenclosurebattery` / drive summary.
- **Panel**: a "FlashSystem" tab on the storage view, shipped inside the
  existing `flashsystem-gui.js` snippet — no new install mechanism.
- **Complementary path**: a small Prometheus exporter for shops that already
  run Grafana — the PVE panel is for at-a-glance state, Grafana for history
  and alerting. Either can land first; they share the metric list.

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
