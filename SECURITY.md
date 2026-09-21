# Security and reliability review

Audit of `FlashSystemPlugin.pm` / `api/FlashSystemAPI.pm` against command
injection, unsafe host calls, TLS, credential handling, races, retries, and
Proxmox Perl conventions. Copilot (`mai-code-1.1-flash`) produced a first
pass; this file is the prioritized report after that pass was reviewed and
the regressions were fixed.

Status: **implemented in this tree** unless marked residual.

## Critical

None remaining. The production-proven SCSI resize/taint path is intact.

## High

| ID | Finding | Resolution |
|---|---|---|
| H1 | TLS verify was off by default (self-signed array certs). Copilot flipped it on with no escape hatch, which would break every existing 8.7 cluster. | Default is now **verify against the host trust store**. Pin a custom CA with `fscafile`. Lab arrays with a self-signed cert set **`fsinsecure=1`** (one-time warning). |
| H2 | Copilot’s `_write_sysfs_value` swallowed `$@` and warned internally. `_rescan_paths` / `_flush_device` then reported empty errors — the 2026-08-31 diagnosis (taint vs slow array) would have gone dark again. | Returns `(ok, error)`. Callers put the error in the task log. |
| H3 | Copilot aborted `_resize_host_device` when &lt;50% of paths accepted the first rescan. That is the opposite of the measured production behaviour (wait; do not thrash). | Early abort **removed**. Incomplete rescans still appear in the final failure message. |
| H4 | Transport retry matched `/SSL\|connect/`, so a certificate-verify failure would be retried with sleep and could stall `pvestatd`. | Cert/hostname failures are not retried. Transient connect/reset/DNS/timeout still are. |
| H5 | Retry helper was off-by-one (`max_attempts => 3` could issue 4 calls) and passed `reauth_done` by value so the flag was dead. Backoff included 8s, which blows `status()`’s 10s alarm. | `max_attempts` is total `$cb` calls. 401/403 re-auth is extra. Backoff is 1/2/4s. |

## Medium

| ID | Finding | Resolution |
|---|---|---|
| M1 | `fspassword` in `storage.cfg` is still accepted. Copilot warned on **every** `status()` poll. | One-time warning per storage id. Prefer the `.pw` file; add/update hooks still strip the property. |
| M2 | Password file write used a world-readable-umask window. Storage id was not validated before interpolation into a path. | `umask 0077` around the write; storage id must match `[A-Za-z0-9][A-Za-z0-9.\-_]*`. |
| M3 | Auth JSON parse errors dumped the raw body (can contain a JWT). | Body truncated to 200 chars; JWT-shaped tokens redacted. |
| M4 | `nvme connect-all --traddr` took `fsnvmeaddr` unchecked. Array-form `run_command` is not a shell, but garbage/newlines should still die. | `_valid_nvme_addr`; port 1–65535; NQN charset check. |
| M5 | NVMe `rescan_controller` paths come from `glob()` and are tainted; write opens fail under `perl -T`. | Untaint with a tight `/sys/class/nvme/nvme\d+/rescan_controller` capture. |
| M6 | `_run_host_cmd` warned when `command -v rescan-scsi-bus.sh` was missing — the normal fallback path, every activate. | Availability check is `quiet => 1`. Real `multipath` / `nvme` failures still warn. |
| M7 | Health-panel errors were opaque. | Non-timeout section errors are prefixed (`auth`, `transient REST`, `bad JSON`, `backend`). Timeout strings are unchanged (load-bearing test). |

## Low

| ID | Finding | Resolution |
|---|---|---|
| L1 | `activate_volume` mixed SCSI and NVMe in one sub. | Split into `_activate_scsi_volume` / `_activate_nvme_volume`. |
| L2 | Host `run_command(..., noerr => 1)` discarded exit status. | `_run_host_cmd` logs non-zero unless `quiet`. |
| L3 | Duplicate sysfs write evals. | Single `_write_sysfs_value`. |
| L4 | Retry loop duplicated in `_auth` / `_cmd`. | `_request_with_retry` + `_sleep` test seam. |

## Residual (not done here)

| ID | Why not |
|---|---|
| R1 | In-process `%TOKENS` / `%UA` are not locked. PVE workers are separate processes; pvestatd is single-threaded. A mutex would not help across processes. |
| R2 | `sh -c` SCSI host scan is a **static** script (no interpolation). Replacing it with a Perl glob+sysfs write is nicer but not a security fix. |
| R3 | IBM REST still allows only one CLI at a time cluster-wide. We retry 429; we do not queue across nodes. |
| R4 | GUI still patches `pvemanagerlib.js`. That is an install-time integrity issue, not a runtime injection bug. |

## Command-injection notes

Volume names, prefixes, and WWIDs used with `run_command([ ... ])` are
**argv arrays**, not a shell. `parse_volname` rejects spaces, slashes, and
non-ASCII. NVMe discovery addresses are now charset-validated. Do not change
those calls to `sh -c "$cmd"`.
