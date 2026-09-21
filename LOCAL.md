# Local fork vs upstream

This directory started as a clone of
[olemyk/ibm-flashsystem-proxmox-plugin](https://github.com/olemyk/ibm-flashsystem-proxmox-plugin)
(SCSI-FC, firmware 8.7, PVE 9.2) and adds the changes needed for
**Proxmox VE 9.2 + IBM FlashSystem 7600 / Storage Virtualize 9.1.3.1**, plus
NVMe-oF.

The SCSI-FC provision/resize/migrate path is unchanged in behaviour. New
code paths are unit-tested; they are **not** hardware-validated on a 7600.

## Must

| Change | Where |
|---|---|
| Re-auth on HTTP **403** as well as 401 (9.1 JWT expiry is 403, default 1 h, wall-clock) | `_cmd`, `_auth` |
| Refresh JWT `exp` 60 s early so `pvestatd` does not sit on a dead token | `_jwt_needs_refresh` |
| Default create command is `mkvolume`; skip `-thin` when the pool has a provisioning policy | `_alloc_create`, `_mkvolume_params` |
| `status()` also accepts 9.x `usable_*` capacity fields | `_pool_usage` |

## Should

| Change | Where |
|---|---|
| `volume_resize` dies if `$snapname` is set (API 15) | `volume_resize` |
| `api()` clamped to 15 instead of blindly claiming the host APIVER | `api` |
| `get_identity()` returns `lssystem` id/name | `get_identity` |
| `fspassword` declared sensitive; add/update hooks write `/etc/pve/priv/storage/<id>.pw` | `plugindata`, `on_add_hook` |
| Optional `fscafile` enables TLS verify | `_ua` |
| `rename_volume` via `chvdisk -name` | `rename_volume`, `volume_has_feature` |

## Nice / NVMe-oF

| Change | Where |
|---|---|
| `fstransport=scsi-fc\|nvme-fc\|nvme-tcp\|nvme-rdma` | `_transport`, `activate_volume`, `path` |
| NVMe namespace lookup by NGUID/EUI (`/dev/disk/by-id/nvme-eui.<uid>`) | `_nvme_path_from_vdisk` |
| `nvme connect-all` using `fsnvmeaddr` | `_nvme_connect` |
| NVMe resize via controller rescan (no dm-multipath) | `_resize_nvme_device` |
| `fsvolumegroup` on `mkvolume`; delete errors name the group | `_mkvolume_params`, `free_image` |

Keep `fscreate=mkvdisk` if you need the exact 8.7 `mkvdisk -rsize` path.

## What was not rewritten

Host-side SCSI resize (taint-safe sysfs, settle loop), 429 backoff, prefix
isolation, 63-character gate, snapshot-by-id, and the health/overview API.
Those stay as upstream left them.
