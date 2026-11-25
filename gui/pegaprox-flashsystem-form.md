# PegaProx Add/Edit form for the FlashSystem storage

Proxmox VE 9.3 generates this dialog itself from the plugin schema, so a
Proxmox 9.3 UI no longer needs the injected Add panel. PegaProx still has
its own form. This draft is only for that form.

Draft against PegaProx `main` as of 2026-11-17. This is not installed by
`install-flashsystem-gui.sh`. PegaProx has its own UI. The Proxmox dialog
in `flashsystem-gui.js` does not load there.

PegaProx already copies every non-empty field on
`POST /api/clusters/<id>/datacenter/storage` through to Proxmox
`POST /api2/json/storage` (`pegaprox/api/storage.py`, `create_storage`).
No new proxy is required. Three edits make the type usable:

1. `web/src/datacenter.js` — type button, fields, required keys, save via PUT when the id already exists.
2. `pegaprox/api/storage.py` — the same required keys, so a partial POST is rejected before it hits Proxmox.
3. `web/src/create_modals.js` — disk format `raw` only.

The plugin must already be installed on the node PegaProx uses as the API
endpoint. Proxmox rejects `type=flashsystem` on a node that has not loaded
`FlashSystemPlugin.pm`. Every node that will activate a volume needs it too.

The PegaProx API account needs Proxmox `Datastore.Allocate` on `/` to
create a storage. The least-privilege role published in the PegaProx docs
has `Datastore.AllocateSpace` and `Datastore.AllocateTemplate` only.
`root@pam` can create it. A token limited to that published role cannot.

Do not send `fscreate`. Storage Virtualize 9.1 and newer create volumes
with `mkvolume`. Any other `fscreate` value is rejected by the plugin.

## 1. Type button

In `storageTypes` (next to the ESXi entry):

```javascript
{ id: 'flashsystem', label: 'IBM FlashSystem', icon: '💾' },
```

In the type-button `onClick`, after the `starlvm` default:

```javascript
if (st.id === 'flashsystem') {
    base.shared = true;
    base.content = 'images';
    base.fstransport = 'scsi-fc';
}
```

`shared` stays on. A host-cluster mapping is visible to every node. With
`shared` off, Proxmox copies the disk on migrate instead of handing over
the multipath map.

When the dialog is editing an existing storage (`storage.some(s => s.storage === newStorage.storage)`),
do not let the type grid change `type`. Proxmox cannot change a storage
type after creation. `fsaddress`, `fspool`, `fsprefix`, and `fstransport`
are `fixed` in the plugin: render them read-only on edit.

## 2. Required keys

Frontend `requiredFields` inside `createStorage`, and the same map in
`pegaprox/api/storage.py`:

```javascript
flashsystem: ['fsaddress', 'fsuser', 'fspool', 'fshostgroup', 'fsprefix'],
```

`fspassword` is optional. Blank means "use `/etc/pve/priv/storage/<id>.pw`"
on create, and "leave the current password" on edit. The create path
already drops empty strings, which is what Proxmox needs.

## 3. Save an edit with PUT

`createStorage` always POSTs. The button label switches to Save when the
id exists, but the request is still a create, so Save fails for every
type. For this form, branch before the request:

```javascript
const editing = storage.some(s => s.storage === storageData.storage);
const url = editing
    ? `${API_URL}/clusters/${clusterId}/datacenter/storage/${encodeURIComponent(storageData.storage)}`
    : `${API_URL}/clusters/${clusterId}/datacenter/storage`;
const res = await fetch(url, {
    method: editing ? 'PUT' : 'POST',
    credentials: 'include',
    headers: { ...authHeaders, 'Content-Type': 'application/json' },
    body: JSON.stringify(storageData),
});
```

On edit, delete `type` and `storage` from the body (the PUT handler in
`storage.py` drops them too) and also delete the fixed keys so a resave
does not try to change them:

```javascript
if (editing && storageData.type === 'flashsystem') {
    delete storageData.type;
    delete storageData.storage;
    delete storageData.fsaddress;
    delete storageData.fspool;
    delete storageData.fsprefix;
    delete storageData.fstransport;
    delete storageData.fscreate;
}
```

## 4. Form block

Paste after the ESXi block (`newStorage.type === 'esxi'`). `editing` is
the same `storage.some(...)` test as the Save button. ID and Nodes stay
in the common header. This block does not repeat them.

```jsx
{newStorage.type === 'flashsystem' && (
    <div className="space-y-4">
        <p className="text-xs text-gray-500">
            Storage Virtualize 9.1 or newer. The plugin must be installed on
            every node. Volumes are raw block devices, one per VM disk.
        </p>
        <div className="grid grid-cols-2 gap-4">
            <div>
                <label className="block text-sm text-gray-400 mb-1">Management address *</label>
                <input value={newStorage.fsaddress || ''} disabled={editing}
                    onChange={e => setNewStorage({...newStorage, fsaddress: e.target.value})}
                    placeholder="array management IP or host"
                    className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm font-mono disabled:opacity-60" />
            </div>
            <div>
                <label className="block text-sm text-gray-400 mb-1">Pool (mdiskgrp) *</label>
                <input value={newStorage.fspool || ''} disabled={editing}
                    onChange={e => setNewStorage({...newStorage, fspool: e.target.value})}
                    placeholder="Pool0"
                    className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm font-mono disabled:opacity-60" />
            </div>
            <div>
                <label className="block text-sm text-gray-400 mb-1">REST username *</label>
                <input value={newStorage.fsuser || ''}
                    onChange={e => setNewStorage({...newStorage, fsuser: e.target.value})}
                    placeholder="Administrator role"
                    className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm" />
            </div>
            <div>
                <label className="block text-sm text-gray-400 mb-1">
                    REST password {editing ? '' : '(optional)'}
                </label>
                <input type="password" value={newStorage.fspassword || ''} autoComplete="new-password"
                    onChange={e => setNewStorage({...newStorage, fspassword: e.target.value})}
                    placeholder={editing ? 'unchanged' : 'prefer the .pw file'}
                    className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm" />
            </div>
            <div>
                <label className="block text-sm text-gray-400 mb-1">Host cluster *</label>
                <input value={newStorage.fshostgroup || ''}
                    onChange={e => setNewStorage({...newStorage, fshostgroup: e.target.value})}
                    placeholder="array host cluster of every PVE node"
                    className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm font-mono" />
            </div>
            <div>
                <label className="block text-sm text-gray-400 mb-1">Prefix *</label>
                <input value={newStorage.fsprefix || ''} disabled={editing}
                    onChange={e => setNewStorage({...newStorage, fsprefix: e.target.value})}
                    placeholder="cluster name, 14 characters or fewer"
                    className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm font-mono disabled:opacity-60" />
            </div>
            <div>
                <label className="block text-sm text-gray-400 mb-1">I/O group</label>
                <input value={newStorage.fsiogrp || ''}
                    onChange={e => setNewStorage({...newStorage, fsiogrp: e.target.value})}
                    placeholder="io_grp0"
                    className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm font-mono" />
            </div>
            <div>
                <label className="block text-sm text-gray-400 mb-1">Transport</label>
                <select value={newStorage.fstransport || 'scsi-fc'} disabled={editing}
                    onChange={e => setNewStorage({...newStorage, fstransport: e.target.value})}
                    className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm disabled:opacity-60">
                    <option value="scsi-fc">SCSI Fibre Channel</option>
                    <option value="nvme-fc">NVMe over Fibre Channel</option>
                    <option value="nvme-tcp">NVMe over TCP</option>
                    <option value="nvme-rdma">NVMe over RDMA</option>
                </select>
            </div>
            <div>
                <label className="block text-sm text-gray-400 mb-1">Content</label>
                <select value={newStorage.content || 'images'}
                    onChange={e => setNewStorage({...newStorage, content: e.target.value})}
                    className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm">
                    <option value="images">Disk image</option>
                    <option value="rootdir">Container</option>
                    <option value="images,rootdir">Disk image, Container</option>
                </select>
            </div>
            <div className="flex items-center gap-4">
                <label className="flex items-center gap-2 text-sm">
                    <input type="checkbox" className="rounded"
                        checked={newStorage.enabled !== false}
                        onChange={e => setNewStorage({...newStorage, enabled: e.target.checked})} />
                    Enable
                </label>
                <label className="flex items-center gap-2 text-sm">
                    <input type="checkbox" className="rounded"
                        checked={!!newStorage.shared}
                        onChange={e => setNewStorage({...newStorage, shared: e.target.checked})} />
                    Shared
                </label>
            </div>
            <div className="col-span-2 flex flex-wrap gap-4">
                <label className="flex items-center gap-2 text-sm">
                    <input type="checkbox" className="rounded"
                        checked={!!newStorage.fsthin}
                        onChange={e => setNewStorage({...newStorage, fsthin: e.target.checked})} />
                    Thin provision new volumes
                </label>
                <label className="flex items-center gap-2 text-sm">
                    <input type="checkbox" className="rounded"
                        checked={!!newStorage.fssnapshots}
                        onChange={e => setNewStorage({...newStorage, fssnapshots: e.target.checked})} />
                    Array snapshots
                </label>
            </div>
            <p className="col-span-2 text-xs text-gray-500 -mt-2">
                Thin uses mkvolume -thin and is ignored when the pool has a
                provisioning policy. Snapshots use addsnapshot. Validate both
                on a scratch pool before relying on them.
            </p>
        </div>

        {(newStorage.fstransport && newStorage.fstransport !== 'scsi-fc') && (
            <div className="grid grid-cols-2 gap-4">
                <div className="col-span-2">
                    <label className="block text-sm text-gray-400 mb-1">NVMe discovery</label>
                    <input value={newStorage.fsnvmeaddr || ''}
                        onChange={e => setNewStorage({...newStorage, fsnvmeaddr: e.target.value})}
                        placeholder="TCP/RDMA IPs, or FC nn-0xWWNN:pn-0xWWPN"
                        className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm font-mono" />
                </div>
                <div>
                    <label className="block text-sm text-gray-400 mb-1">NVMe TCP/RDMA port</label>
                    <input value={newStorage.fsnvmeport || ''}
                        onChange={e => setNewStorage({...newStorage, fsnvmeport: e.target.value})}
                        placeholder="4420"
                        className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm font-mono" />
                </div>
                <div>
                    <label className="block text-sm text-gray-400 mb-1">Subsystem NQN</label>
                    <input value={newStorage.fsnvmesubnqn || ''}
                        onChange={e => setNewStorage({...newStorage, fsnvmesubnqn: e.target.value})}
                        placeholder="empty = connect-all discovers it"
                        className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm font-mono" />
                </div>
            </div>
        )}

        <div className="grid grid-cols-2 gap-4">
            <div className="col-span-2">
                <label className="block text-sm text-gray-400 mb-1">Volume group</label>
                <input value={newStorage.fsvolumegroup || ''}
                    onChange={e => setNewStorage({...newStorage, fsvolumegroup: e.target.value})}
                    placeholder="existing array volume group (PBR/PBHA)"
                    className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm font-mono" />
            </div>
            <div className="col-span-2">
                <label className="block text-sm text-gray-400 mb-1">TLS CA file</label>
                <input value={newStorage.fscafile || ''}
                    onChange={e => setNewStorage({...newStorage, fscafile: e.target.value})}
                    placeholder="path on the node; empty uses the host trust store"
                    className="w-full bg-proxmox-dark border border-proxmox-border rounded p-2 text-sm font-mono" />
            </div>
            <div className="col-span-2">
                <label className="flex items-center gap-2 text-sm">
                    <input type="checkbox" className="rounded"
                        checked={!!newStorage.fsinsecure}
                        onChange={e => setNewStorage({...newStorage, fsinsecure: e.target.checked})} />
                    Skip certificate verify (self-signed lab only)
                </label>
            </div>
        </div>
    </div>
)}
```

`editing` has to be in scope for the JSX. Next to `createStorage` is fine:

```javascript
const editing = storage.some(s => s.storage === newStorage.storage);
```

The type grid's `grid-cols-5` wraps the fifteenth button onto the next row.
No layout change is required.

## 5. VM disk format

In `web/src/create_modals.js`, `STORAGE_FORMATS`:

```javascript
flashsystem: ['raw'],
```

Without that entry the create wizard offers raw, qcow2, and vmdk. The
plugin accepts raw only. The disk picker already lists a storage whose
content contains `images` or `rootdir`, so a created FlashSystem storage
shows up there without a further change.

## What this form does not do

It does not install the Perl plugin, zone Fibre Channel, or create the
array host cluster. It does not add the FlashSystem health tab. That tab
is patched into `pvemanagerlib.js` and stays on the Proxmox UI.
