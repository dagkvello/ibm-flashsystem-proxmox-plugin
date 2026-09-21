# Policy-based replication and PBHA — effort

The plugin now has **awareness**, not orchestration. New volumes can join an
**existing** volume group (`fsvolumegroup`). Deletes that fail because the
volume is in a replicated group or HA partition fail with an actionable
message instead of retrying blindly. The plugin does **not** create
replication policies, pool links, partitions, or partnerships, and it does
**not** run failover.

That is the right first step: PBR/PBHA are array-owned consistency groups.
Driving them from every `pvesm alloc` without a group model will split a
VM's disks across groups or delete a member out of a replicating set.

## What "awareness" already covers

- Place new disks in a pre-created volume group (and therefore in whatever
  replication or HA policy that group already has).
- Honour a pool provisioning policy (do not send `-thin` on top of it).
- Refuse to guess when `rmvdisk` is blocked by the group/partition.

Operator work still done on the array (or Ansible):

1. Partnership / pool links / replication policy.
2. Volume group (and, for PBHA, the storage partition).
3. Host cluster in that partition, mapped at both sites.

Then point the Proxmox storage at that group.

## Full PBR from Proxmox — estimate

| Slice | Scope | Effort |
|---|---|---|
| **A. Group-per-VM** | One volume group per guest, created on first disk, all subsequent disks join it. Snapshot of a VM = array snapshot of that group. | **1–2 weeks** |
| **B. Status in PVE** | Surface `lsvolumegroupreplication` / copy state on the health tab (running, disconnected, independent). | **3–5 days** on top of A |
| **C. Failover runbook in PVE** | Buttons/CLI to `chvolumegroupreplication -mode independent`, remap hosts on the recovery system, import VMs. Needs a recovery-site PVE cluster or a stretched cluster that can see recovery LUNs. | **4–8 weeks** — most of the work is PVE lifecycle, not REST |
| **D. Dual-site alloc** | `mkvolume` with two pools when the policy is stretched/HA. Only valid from the **active management system**. | **1–2 weeks**, after A |

A+B is useful and relatively safe. C is a product, not a plugin tweak: you
have to decide whether recovery Proxmox is a second cluster (import backups /
recreate VM configs) or the same stretched cluster (LUNs appear with the
same UID at the other site). IBM PBR recovery volumes are different objects
with different names unless you are on PBHA.

**Realistic total for production PBR from PVE: 6–10 weeks** including
scratch-array testing, plus a written failover runbook. Do not start C until
A is stable.

## PBHA (policy-based HA) — estimate

PBHA is a **storage partition** with an HA replication policy. Volumes are
the same UID on both systems. That is a much better fit for a Proxmox
**stretched cluster** (`shared=1`, host cluster at both sites, live
migration across sites).

| Slice | Scope | Effort |
|---|---|---|
| **E. Partition-aware REST** | Talk to the partition IP (9.1 restricted partition view). Refuse create/delete on the non-active management system with a clear error. | **1 week** |
| **F. Stretched activate** | Same `vdisk_UID` / NGUID on both sites, so `path()` already works if both sites' hosts are in the host cluster. Confirm SCSI vs NVMe mapping at both sites. | **3–5 days** of validation more than code |
| **G. Quorum / independent access** | Detect partition split, freeze alloc/delete, tell the operator which site is active. | **1–2 weeks** |
| **H. Partition create/migrate** | Out of scope for a storage plugin. Use IBM GUI / Ansible / the existing PBHA-for-IBM docs. | **n/a** |

**Realistic total for PBHA-aware plugin (E+F+G): 3–5 weeks**, assuming the
partition, host clusters, and stretched fabric already exist.

9.1.3 adds NVMe-oF partition migration and sync PBR. Those are array
features; the plugin only has to keep using host-cluster maps and not
assume SCSI LUN IDs.

## Recommended sequence

1. Deploy this fork on SCSI-FC or one NVMe transport against a **scratch
   pool** (JWT 403, `mkvolume`, resize).
2. Create one volume group with a replication policy on the array, set
   `fsvolumegroup`, prove a VM's disks land in it and replicate.
3. Only then decide whether you want group-per-VM (slice A) or are happy
   with one group per Proxmox storage (current `fsvolumegroup`).
4. PBHA: stretched PVE cluster + partition IP, then E+F.

Trying to implement C (failover) before A and a tested fabric will cost
more than the REST work.
