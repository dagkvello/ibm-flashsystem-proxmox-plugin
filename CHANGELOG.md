# Changelog

Pre-release history, condensed from internal deployment tags. Dates are when
the change reached a 12-node production cluster (PVE 9.2, firmware 8.7).

## Unreleased — 2026-08-26

- **Thin provisioning** (`fsthin`): opt-in `mkvdisk -rsize 2% -autoexpand
  -warning 80%` for new volumes, with a matching GUI checkbox. Off by
  default; bare mkvdisk volumes are fully allocated (confirmed via
  `lsvdisk` `capacity` == `real_capacity`), which also bypasses DRP
  thin/dedup.
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
