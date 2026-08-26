// ---------------------------------------------------------------------------
// GUI add/edit support for the custom `flashsystem` storage type.
//
// Proxmox's Datacenter > Storage "Add"/"Edit" dialogs are defined entirely in
// the pve-manager frontend (pvemanagerlib.js), which has NO plugin API - so a
// custom backend storage plugin never appears in the "Add" menu and has no
// edit form. This file fills that gap: it defines an ExtJS input panel and
// registers the `flashsystem` type in PVE.Utils.storageSchema.
//
// It is appended to /usr/share/pve-manager/js/pvemanagerlib.js by
// install-flashsystem-gui.sh, which also installs an APT post-invoke hook to
// re-append it after pve-manager upgrades (those rewrite that file). Run the
// installer on EVERY node. See README.md ("GUI add/edit").
//
// Field/idiom conventions mirror PVE 9.x PVE.storage.CIFSInputPanel:
//   - fixed-on-edit fields render as a textfield on create, displayfield on edit
//   - the password is blank on edit and dropped when left empty (= "unchanged")
// ---------------------------------------------------------------------------

Ext.define('PVE.storage.FlashSystemInputPanel', {
    extend: 'PVE.panel.StorageBase',

    onGetValues: function (values) {
        let me = this;
        // Leave the password blank to keep the current one. The plugin prefers
        // the root-only /etc/pve/priv/storage/<id>.pw file over a plaintext
        // value in storage.cfg anyway, so blank is the recommended case.
        if (values.fspassword?.length === 0) {
            delete values.fspassword;
        }
        if (values.fsiogrp?.length === 0) {
            delete values.fsiogrp;
        }
        // LOCAL PATCH (see UPSTREAM.md): a host-cluster-mapped volume is
        // visible to every node by construction, so this storage type is
        // inherently shared. Without this, GUI-created storages defaulted to
        // shared=0 and migration would try to copy the disk instead of
        // handing over the multipath map.
        if (me.isCreate) {
            values.shared = 1;
        }
        return me.callParent([values]);
    },

    initComponent: function () {
        let me = this;

        me.column1 = [
            {
                // fixed => 1 in the plugin: settable only at creation time.
                xtype: me.isCreate ? 'textfield' : 'displayfield',
                name: 'fsaddress',
                value: '',
                fieldLabel: gettext('Management address'),
                allowBlank: false,
            },
            {
                // fixed => 1 in the plugin: settable only at creation time.
                xtype: me.isCreate ? 'textfield' : 'displayfield',
                name: 'fspool',
                value: '',
                fieldLabel: gettext('Pool (mdiskgrp)'),
                allowBlank: false,
            },
            {
                xtype: 'textfield',
                name: 'fshostgroup',
                value: '',
                fieldLabel: gettext('Host cluster'),
                allowBlank: false,
            },
            {
                // LOCAL PATCH (fsprefix, see UPSTREAM.md): fixed => 1 in the
                // plugin, so create-only. Required by policy here, not by the
                // plugin schema: pools are shared between clusters, and a
                // storage created without a prefix can never gain one — the
                // 2026-08-12 trial storage had to be created from the CLI
                // because this field was missing.
                xtype: me.isCreate ? 'textfield' : 'displayfield',
                name: 'fsprefix',
                value: '',
                emptyText: gettext('e.g. the cluster name'),
                fieldLabel: gettext('Prefix'),
                allowBlank: false,
            },
        ];

        me.column2 = [
            {
                xtype: 'pveContentTypeSelector',
                name: 'content',
                value: 'images',
                multiSelect: true,
                // LOCAL PATCH (see UPSTREAM.md): only offer what the plugin's
                // plugindata declares. The unrestricted selector listed ISO,
                // backup, templates and snippets — all file-storage content
                // that a raw-block plugin cannot hold, failing only at submit.
                cts: ['images', 'rootdir'],
                fieldLabel: gettext('Content'),
                allowBlank: false,
            },
            {
                xtype: 'textfield',
                name: 'fsuser',
                value: '',
                fieldLabel: gettext('REST username'),
                allowBlank: false,
            },
            {
                xtype: 'textfield',
                inputType: 'password',
                name: 'fspassword',
                value: '',
                emptyText: me.isCreate
                    ? gettext('optional - prefer the .pw file')
                    : gettext('unchanged'),
                fieldLabel: gettext('REST password'),
                allowBlank: true,
            },
            {
                xtype: 'textfield',
                name: 'fsiogrp',
                value: '',
                emptyText: 'io_grp0',
                fieldLabel: gettext('I/O group'),
                allowBlank: true,
            },
        ];

        me.advancedColumn1 = [
            {
                xtype: 'proxmoxcheckbox',
                name: 'fssnapshots',
                uncheckedValue: 0,
                fieldLabel: gettext('Array snapshots'),
                boxLabel: gettext('enable (validate firmware first)'),
            },
            {
                // LOCAL PATCH (fsthin, see UPSTREAM.md): thin-provision NEW
                // volumes (mkvdisk -rsize 2% -autoexpand). Existing volumes
                // keep their allocation. Thin = overcommit — make sure
                // array-side physical-free alerting exists before enabling
                // on pools shared with other workloads.
                xtype: 'proxmoxcheckbox',
                name: 'fsthin',
                uncheckedValue: 0,
                fieldLabel: gettext('Thin provision'),
                boxLabel: gettext('new volumes only'),
            },
        ];

        me.callParent();
    },
});

// Register the type so it shows in the "Add" dropdown and gets an Edit dialog.
// storageSchema is a plain object on the PVE.Utils singleton, already defined
// by the time this appended code runs.
if (typeof PVE !== 'undefined' && PVE.Utils && Ext.isObject(PVE.Utils.storageSchema)) {
    PVE.Utils.storageSchema.flashsystem = {
        name: 'IBM FlashSystem',
        ipanel: 'FlashSystemInputPanel',
        faIcon: 'database',
    };
}

// ---------------------------------------------------------------------------
// LOCAL PATCH (health panel, see UPSTREAM.md section 3): a "FlashSystem" tab
// on the storage view showing array health and capacity, fed by the
// GET /nodes/{node}/flashsystem/{storage}/health endpoint that
// install-flashsystem-api.sh registers. Read-only; sections degrade
// independently when the array is slow or unreachable.
// ---------------------------------------------------------------------------

Ext.define('PVE.storage.FlashSystemHealthPanel', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveFlashSystemHealthPanel',

    scrollable: true,
    bodyPadding: 15,
    html: '<div class="fs-health">' + gettext('Loading...') + '</div>',

    tbar: [
        {
            text: gettext('Refresh'),
            iconCls: 'fa fa-refresh',
            handler: function() {
                this.up('panel').reloadHealth();
            },
        },
    ],

    fmtBytes: function(v) {
        if (v === undefined || v === null) { return '-'; }
        return Proxmox.Utils.format_size(v);
    },

    esc: Ext.htmlEncode,

    // Storage Virtualize event timestamps are YYMMDDHHMMSS.
    fmtEventTime: function(t) {
        let m = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/.exec(String(t || ''));
        if (!m) { return t || ''; }
        return `20${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}`;
    },

    renderHealth: function(d) {
        let me = this;
        let e = me.esc;
        let h = [];
        let row = (k, v) => `<tr><td style="padding:2px 14px 2px 0;color:#888;white-space:nowrap;">${e(k)}</td><td style="padding:2px 0;">${v}</td></tr>`;
        let head = t => `<h3 style="margin:14px 0 6px;">${e(t)}</h3>`;

        if (d.system) {
            h.push(head(gettext('System')));
            h.push('<table>');
            h.push(row(gettext('Name'), e(d.system.name || '-')));
            h.push(row(gettext('Product'), e(d.system.product_name || '-')));
            h.push(row(gettext('Firmware'), e(d.system.code_level || '-')));
            h.push('</table>');
        }

        if (d.pool) {
            let p = d.pool;
            let pct = p.provision_used_pct || 0;
            let color = pct >= 90 ? '#c0392b' : (pct >= 75 ? '#c87f0a' : '#2d7d46');
            h.push(head(gettext('Pool') + ' ' + (d.pool_name || p.name || '')));
            h.push(`<div style="max-width:420px;background:#eee;border:1px solid #ccc;border-radius:3px;height:18px;position:relative;">`
                + `<div style="background:${color};width:${Math.min(pct, 100)}%;height:100%;border-radius:2px;"></div>`
                + `<span style="position:absolute;top:0;left:8px;font-size:11px;line-height:18px;color:#000;">${pct}% ${e(gettext('of physical'))}</span></div>`);
            h.push('<table style="margin-top:6px;">');
            h.push(row(gettext('Physical (usable)'),
                `${me.fmtBytes(p.provision_used)} / ${me.fmtBytes(p.provision_total)} (${me.fmtBytes(p.provision_free)} ${e(gettext('free'))})`));
            if (p.physical_capacity && p.capacity && +p.capacity !== +p.physical_capacity) {
                h.push(row(gettext('Effective (after reduction)'),
                    `${me.fmtBytes(p.capacity - p.free_capacity)} / ${me.fmtBytes(p.capacity)}`));
            }
            if (p.data_reduction) {
                h.push(row(gettext('Data reduction'), e(p.data_reduction)));
            }
            if (p.status) {
                h.push(row(gettext('Status'), e(p.status)));
            }
            h.push('</table>');
        }

        if (d.volumes) {
            h.push(head(gettext('Volumes')));
            h.push('<table>');
            h.push(row(gettext('This storage'),
                `${d.volumes.ours} (${me.fmtBytes(d.volumes.ours_provisioned)} ${e(gettext('provisioned'))})`));
            h.push(row(gettext('Whole pool'), `${d.volumes.pool_total}`));
            // An unprefixed storage shares the pool's namespace with every
            // other consumer and cannot be isolated from them. fsprefix is
            // fixed at creation, so this only gets more expensive to fix.
            h.push(row(gettext('Array name prefix'), d.prefix
                ? e(d.prefix)
                : '<i class="fa fa-exclamation-triangle" style="color:#c87f0a;"></i> '
                  + e(gettext('none — objects are unprefixed and share the pool namespace'))));
            h.push('</table>');
        }

        if (d.ports) {
            let ok = d.ports.active === d.ports.total;
            h.push(head(gettext('FC ports')));
            h.push(`<div>${ok ? '' : '<i class="fa fa-exclamation-triangle" style="color:#c87f0a;"></i> '}`
                + `${d.ports.active} / ${d.ports.total} ${e(gettext('active'))}</div>`);
        }

        // Ranked consumers for THIS storage — same rows the volume count was
        // taken from, so no extra array traffic.
        if (d.top && d.top.volumes && d.top.volumes.length) {
            h.push(head(gettext('Largest volumes')));
            h.push(PVE.FlashSystemUI.renderTop(d.top, 'health', me.topSort));
        }

        if (d.events) {
            // Alerts only. The array's unfixed log is mostly informational
            // chatter (copy-format notices, SAS discovery) — showing that raw
            // count would bury a real pool-space warning under four figures.
            let alerts = d.events.alerts || 0;
            h.push(head(gettext('Array alerts')));
            h.push('<div>'
                + (alerts === 0
                    ? '<i class="fa fa-check" style="color:#2d7d46;"></i> ' + e(gettext('No unfixed alerts'))
                    : `<i class="fa fa-exclamation-triangle" style="color:#c0392b;"></i> <b>${alerts}</b> ${e(gettext('unfixed'))}`)
                // Shown only when the whole unfixed log was fetched: under the
                // server-side alert filter those informational events are not
                // in the payload, and printing 0 would claim there are none.
                + (d.events.unfixed_total === undefined
                    ? ''
                    : ` <span style="color:#888;">(${d.events.unfixed_total} ${e(gettext('unfixed events array-wide, incl. informational'))})</span>`)
                + '</div>');
            if (alerts > 0 && d.events.recent && d.events.recent.length) {
                h.push('<table style="font-size:12px;margin-top:6px;">');
                d.events.recent.forEach(ev => {
                    h.push(row(me.fmtEventTime(ev.last_timestamp) || ev.sequence_number || '',
                        `<b>${e(ev.error_code || '')}</b> ${e(ev.description || '')}`
                        + (ev.object_name ? ` <span style="color:#888;">(${e(ev.object_name)})</span>` : '')));
                });
                h.push('</table>');
            }
        }

        if (d.errors) {
            h.push(head(gettext('Sections unavailable')));
            h.push('<table style="font-size:12px;">');
            Object.keys(d.errors).forEach(k => h.push(row(k, e(d.errors[k]))));
            h.push('</table>');
        }

        return '<div class="fs-health">' + h.join('') + '</div>';
    },

    reloadHealth: function() {
        let me = this;
        let sel = me.pveSelNode ? me.pveSelNode.data : {};
        let nodename = me.nodename || sel.node;
        let storage = me.storage || sel.storage;
        if (!nodename || !storage) {
            me.update('<div>' + gettext('No storage selected.') + '</div>');
            return;
        }
        Proxmox.Utils.API2Request({
            url: `/nodes/${nodename}/flashsystem/${storage}/health`,
            method: 'GET',
            waitMsgTarget: me,
            success: function(response) {
                me.healthData = response.result.data || {};
                me.update(me.renderHealth(me.healthData));
            },
            failure: function(response) {
                me.update('<div style="color:#c0392b;">'
                    + Ext.htmlEncode(response.htmlStatus || gettext('Query failed'))
                    + '</div>');
            },
        });
    },

    listeners: {
        activate: function() {
            this.reloadHealth();
        },
        // Same delegated sort as the datacenter panel; the server already
        // returns largest-first, so this is convenience only.
        click: {
            element: 'body',
            fn: function(ev) {
                let me = this;
                let el = ev.getTarget('[data-fssort]', 6);
                if (!el) { return; }
                let key = el.getAttribute('data-fssort');
                if (!key || !me.healthData) { return; }
                me.topSort = me.topSort && me.topSort.key === key
                    ? { key: key, dir: me.topSort.dir === 'asc' ? 'desc' : 'asc' }
                    : { key: key, dir: 'desc' };
                me.update(me.renderHealth(me.healthData));
            },
        },
    },
});

// Mount the tab: PVE.panel.Config consumes `me.items` assembled by
// PVE.storage.Browser BEFORE calling its own initComponent, so intercepting
// Config.initComponent lets us add a tab without re-implementing the
// browser's item assembly. Guarded so any ExtJS-internals drift in a future
// pve-manager degrades to "no tab", never a broken storage view.
// VALIDATE: tested against pve-manager 9.2; re-check after major upgrades.
Ext.define('PVE.storage.FlashSystemConfigOverride', {
    override: 'PVE.panel.Config',
    initComponent: function() {
        let me = this;
        try {
            let sel = me.pveSelNode && me.pveSelNode.data ? me.pveSelNode.data : {};
            if (Ext.isArray(me.items)) {
                if (sel.type === 'storage' && sel.plugintype === 'flashsystem') {
                    // Per-storage health tab.
                    me.items.push({
                        xtype: 'pveFlashSystemHealthPanel',
                        title: 'FlashSystem',
                        itemId: 'flashsystemhealth',
                        iconCls: 'fa fa-heartbeat',
                        nodename: sel.node,
                        storage: sel.storage,
                    });
                } else if (me.hstateid === 'dctab' || sel.id === 'root') {
                    // Datacenter-wide overview. This MUST hook PVE.panel.Config
                    // rather than PVE.dc.Config: the latter assigns me.items = []
                    // as the first statement of its own initComponent, i.e. after
                    // an override on it would have run, so the entry would be
                    // discarded silently.
                    let caps = Ext.state.Manager.get('GuiCap') || {};
                    let maySee = (caps.storage
                            && (caps.storage['Datastore.Audit'] || caps.storage['Datastore.Allocate']))
                        || (caps.dc && caps.dc['Sys.Audit']);
                    if (maySee) {
                        let item = {
                            xtype: 'pveDcFlashSystemOverview',
                            title: 'FlashSystem',
                            itemId: 'flashsystem',
                            iconCls: 'fa fa-hdd-o',
                        };
                        // Sit next to Ceph, where people already look for
                        // storage-fabric status; then Storage; else append.
                        let idx = -1;
                        ['ceph', 'storage'].forEach(function(id) {
                            if (idx < 0) {
                                idx = me.items.findIndex(function(it) { return it && it.itemId === id; });
                            }
                        });
                        if (idx >= 0) {
                            me.items.splice(idx + 1, 0, item);
                        } else {
                            me.items.push(item);
                        }
                    }
                }
            }
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error('flashsystem config tab:', err);
        }
        me.callParent();
    },
});

// ---------------------------------------------------------------------------
// LOCAL PATCH (performance + consumption, see UPSTREAM.md section 3): shared
// rendering for the sections that appear in BOTH the storage tab and the
// datacenter overview — ranked volume/VM consumption and array performance.
//
// The two panels' existing formatters were deliberately duplicated (a dozen
// lines each, one of them production-validated). These sections are ~150
// lines, so they live once, here, and both panels call in.
// ---------------------------------------------------------------------------

Ext.define('PVE.FlashSystemUI', {
    singleton: true,

    esc: Ext.htmlEncode,

    bytes: function(v) {
        if (v === undefined || v === null) { return '&ndash;'; }
        return Proxmox.Utils.format_size(v);
    },

    // Storage Virtualize timestamps are YYMMDDHHMMSS, for both event log and
    // statistic peak times.
    stamp: function(t) {
        let m = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/.exec(String(t || ''));
        if (!m) { return t ? Ext.htmlEncode(String(t)) : ''; }
        return `20${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}`;
    },

    // VMID -> name/node, from the resource store the GUI already keeps warm.
    // This is the join that turns "vm-124-disk-0" into something an operator
    // can act on; the API cannot do it, because VM names are PVE's, not the
    // array's. Guarded: without the store we still render VMIDs.
    vmIndex: function() {
        let map = Object.create(null);
        try {
            PVE.data.ResourceStore.each(function(rec) {
                let d = rec.data;
                if (d.type === 'qemu' || d.type === 'lxc') {
                    map[d.vmid] = { name: d.name, node: d.node, type: d.type };
                }
            });
        } catch (err) {
            // resource store not ready — VMIDs only
        }
        return map;
    },

    vmLabel: function(vmid, idx) {
        let e = Ext.htmlEncode;
        let info = idx[vmid];
        if (!info) { return String(vmid); }
        let bits = [];
        if (info.name) { bits.push(e(info.name)); }
        if (info.node) { bits.push(e(info.node)); }
        if (!bits.length) { return String(vmid); }
        return `${vmid} <span style="color:#888;">(${bits.join(' &middot; ')})</span>`;
    },

    sortRows: function(rows, key, dir) {
        let mul = dir === 'asc' ? 1 : -1;
        return rows.slice().sort(function(a, b) {
            let x = a[key], y = b[key];
            if (x === undefined || x === null) { return 1; }
            if (y === undefined || y === null) { return -1; }
            if (typeof x === 'number' && typeof y === 'number') { return (x - y) * mul; }
            return String(x).localeCompare(String(y)) * mul;
        });
    },

    // Clickable column header. The panel owns the sort state and re-renders;
    // if the delegated handler never fires the table still shows the
    // server's ordering, which is already highest-first.
    th: function(label, key, tableId, state) {
        let e = Ext.htmlEncode;
        let active = state && state.key === key;
        let caret = active ? (state.dir === 'asc' ? ' &#9650;' : ' &#9660;') : '';
        return `<th style="text-align:left;padding:2px 12px 4px 0;color:#888;font-weight:normal;`
            + `cursor:pointer;white-space:nowrap;" data-fssort="${e(key)}" data-fstable="${e(tableId)}">`
            + `${e(label)}${caret}</th>`;
    },

    fillBar: function(pct) {
        let p = Math.max(0, Math.min(100, Number(pct) || 0));
        let color = p >= 90 ? '#c0392b' : (p >= 75 ? '#c87f0a' : '#2d7d46');
        return `<span style="display:inline-block;vertical-align:middle;width:60px;height:8px;`
            + `background:#2a2a2a;border:1px solid #555;border-radius:2px;margin-right:6px;">`
            + `<span style="display:block;width:${p}%;height:100%;background:${color};"></span></span>${p}%`;
    },

    // Ranked consumers. `top` is the API's per-pool (or per-storage) block.
    renderTop: function(top, tableId, state) {
        let me = this;
        let e = Ext.htmlEncode;
        if (!top) { return ''; }
        let idx = me.vmIndex();
        let h = [];

        // Volumes needing attention come FIRST and unconditionally - they are
        // not ranked by size and must not depend on making the top ten. A
        // 32 GiB offline volume in a pool whose largest is 2 TB would never
        // appear otherwise, and fast_write_state=corrupt arrives WITH
        // status=online, so the status column alone renders it as healthy
        // while it is actually waiting on recovervdisk.
        let att = top.attention || [];
        if (att.length) {
            h.push(`<div style="margin-top:8px;padding:6px 8px;border:1px solid #c0392b;`
                + `border-radius:3px;">`
                + '<i class="fa fa-exclamation-triangle" style="color:#c0392b;"></i> '
                + `<b>${e(gettext('Needs attention'))}</b>`
                + (top.attention_total > att.length
                    ? ` <span style="color:#888;">(${e(gettext('showing'))} ${att.length} `
                      + `${e(gettext('of'))} ${top.attention_total})</span>`
                    : '')
                + '<table style="font-size:12px;margin-top:4px;"><tbody>');
            att.forEach(function(v) {
                let flags = [];
                if (v.status && String(v.status).toLowerCase() !== 'online') {
                    flags.push(e(v.status));
                }
                if (v.fast_write_state) {
                    // Not a performance hint: this one needs recovervdisk or
                    // repairvdiskcopy before the guest will start.
                    flags.push(e(gettext('fast-write')) + ' ' + e(v.fast_write_state)
                        + ' &mdash; ' + e(gettext('needs recovervdisk')));
                }
                h.push('<tr>'
                    + `<td style="padding:1px 12px 1px 0;">${me.vmLabel(v.vmid, idx)}</td>`
                    + `<td style="padding:1px 12px 1px 0;">${e(v.name || '')}</td>`
                    + `<td style="padding:1px 12px 1px 0;color:#888;">${e(v.storage || '')}</td>`
                    + `<td style="padding:1px 12px 1px 0;">${me.bytes(v.capacity)}</td>`
                    + `<td style="padding:1px 0;color:#c0392b;">${flags.join(' &middot; ')}</td>`
                    + '</tr>');
            });
            h.push('</tbody></table></div>');
        }

        let vols = top.volumes || [];
        if (vols.length) {
            if (state && state.key) { vols = me.sortRows(vols, state.key, state.dir); }
            // Fill is only knowable for space-efficient volumes: a fully
            // allocated volume reserves its whole size, so the array has no
            // "how full" to report and the number that matters is the size.
            let anyFill = vols.some(function(v) { return v.fill_pct !== undefined; });
            h.push('<table style="font-size:12px;width:100%;margin-top:6px;"><thead><tr>');
            h.push(me.th(gettext('VM'), 'vmid', tableId, state));
            h.push(me.th(gettext('Volume'), 'name', tableId, state));
            h.push(me.th(gettext('Storage'), 'storage', tableId, state));
            h.push(me.th(gettext('Provisioned'), 'capacity', tableId, state));
            if (anyFill) { h.push(me.th(gettext('Used'), 'used', tableId, state)); }
            h.push('</tr></thead><tbody>');
            vols.forEach(function(v) {
                h.push('<tr>'
                    + `<td style="padding:1px 12px 1px 0;">${me.vmLabel(v.vmid, idx)}</td>`
                    + `<td style="padding:1px 12px 1px 0;">${e(v.name || '')}`
                        + (v.status && String(v.status).toLowerCase() !== 'online'
                            ? ` <span style="color:#c0392b;">${e(v.status)}</span>` : '')
                        + (v.thin ? ` <span style="color:#888;">${e(gettext('thin'))}</span>` : '')
                    + '</td>'
                    + `<td style="padding:1px 12px 1px 0;color:#888;">${e(v.storage || '')}</td>`
                    + `<td style="padding:1px 12px 1px 0;">${me.bytes(v.capacity)}</td>`
                    + (anyFill
                        ? `<td style="padding:1px 0;">`
                            + (v.fill_pct === undefined
                                ? '<span style="color:#888;">&ndash;</span>'
                                : `${me.fillBar(v.fill_pct)} <span style="color:#888;">${me.bytes(v.used)} `
                               + e(v.fill_basis === 'allocated'
                                   ? gettext('of allocated')
                                   : gettext('of provisioned')) + '</span>')
                            + '</td>'
                        : '')
                    + '</tr>');
            });
            h.push('</tbody></table>');
        }

        let fill = top.fill;
        if (fill && !fill.available) {
            let why = {
                // The important one: every pmcl01 tier is a DRP.
                'data-reduction-pool': gettext(
                    'Per-volume fill is not reported for volumes in a data reduction pool '
                    + '- the array leaves those fields blank. Sizes below are provisioned capacity.'),
                'query-failed': gettext('The per-volume fill query failed; sizes below are provisioned capacity.'),
                'pool-capacity-unavailable': gettext(
                    'Pool capacity was unavailable, so per-volume fill was not queried.'),
            }[fill.reason] || gettext('Per-volume fill is unavailable.');
            h.push(`<div style="margin-top:6px;font-size:11px;color:#888;max-width:640px;">`
                + '<i class="fa fa-info-circle"></i> ' + e(why) + '</div>');
        }

        let vms = top.vms || [];
        if (vms.length > 1) {
            h.push(`<div style="color:#888;font-size:12px;margin-top:10px;">${e(gettext('By guest'))}</div>`);
            h.push('<table style="font-size:12px;margin-top:2px;"><tbody>');
            vms.forEach(function(v) {
                h.push('<tr>'
                    + `<td style="padding:1px 12px 1px 0;">${me.vmLabel(v.vmid, idx)}</td>`
                    + `<td style="padding:1px 12px 1px 0;color:#888;">${Number(v.disks) || 0} ${e(gettext('disks'))}</td>`
                    + `<td style="padding:1px 0;">${me.bytes(v.capacity)}</td>`
                    + '</tr>');
            });
            h.push('</tbody></table>');
        }

        // Other storages of OURS sharing this pool. Only the storage-scoped
        // view carries this; on pmcl01 it is the k8s-* CSI storage sitting on
        // the same tier, and counting it as another tenant sent a capacity
        // question to the storage team that belonged to our own Kubernetes.
        let sib = top.siblings;
        if (sib && sib.count) {
            h.push(`<div style="color:#888;font-size:12px;margin-top:10px;">`
                + `${e(gettext('Other storages of this cluster in the same pool'))}: `
                + `<b>${sib.count}</b> ${e(gettext('volumes'))}, ${me.bytes(sib.capacity)} `
                + `<span style="color:#666;">(${e(gettext('see Datacenter → FlashSystem for the breakdown'))})</span>`
                + '</div>');
        }

        // Other tenants. On a pool shared with VMware or another cluster this
        // is regularly the largest consumer, and omitting it would point the
        // operator at the wrong place entirely.
        let f = top.foreign;
        if (f && f.count) {
            h.push(`<div style="color:#888;font-size:12px;margin-top:10px;">`
                + `${e(gettext('Not managed by this cluster'))}: <b>${f.count}</b> `
                + `${e(gettext('volumes'))}, ${me.bytes(f.capacity)}</div>`);
            (f.volumes || []).forEach(function(v) {
                if (!v.name) { return; }
                h.push(`<div style="font-size:12px;color:#888;margin-left:14px;">`
                    + `${e(v.name)} &nbsp; ${me.bytes(v.capacity)}</div>`);
            });
        }
        return h.join('');
    },

    // Metric groups mirroring the array GUI's Performance tab. Front-end
    // first: that is what the guests actually experience, and comparing it
    // with the back-end rows is how you tell "the array is busy" from "the
    // drives are struggling".
    PERF_GROUPS: [
        { label: 'Volumes (front end)', spark: true, metrics: [
            { k: 'vdisk_r_io', l: 'Read IOPS' }, { k: 'vdisk_w_io', l: 'Write IOPS' },
            { k: 'vdisk_r_mb', l: 'Read MB/s' }, { k: 'vdisk_w_mb', l: 'Write MB/s' },
            { k: 'vdisk_r_ms', l: 'Read latency' },
            { k: 'vdisk_w_ms', l: 'Write latency' } ] },
        { label: 'MDisks (back end)', metrics: [
            { k: 'mdisk_r_io', l: 'Read IOPS' }, { k: 'mdisk_w_io', l: 'Write IOPS' },
            { k: 'mdisk_r_mb', l: 'Read MB/s' }, { k: 'mdisk_w_mb', l: 'Write MB/s' },
            { k: 'mdisk_r_ms', l: 'Read latency' },
            { k: 'mdisk_w_ms', l: 'Write latency' } ] },
        { label: 'Drives', metrics: [
            { k: 'drive_r_io', l: 'Read IOPS' }, { k: 'drive_w_io', l: 'Write IOPS' },
            { k: 'drive_r_ms', l: 'Read latency' },
            { k: 'drive_w_ms', l: 'Write latency' } ] },
        { label: 'Interfaces', metrics: [
            { k: 'fc_io', l: 'FC IOPS' }, { k: 'fc_mb', l: 'FC MB/s' },
            { k: 'iscsi_io', l: 'iSCSI IOPS' }, { k: 'iscsi_mb', l: 'iSCSI MB/s' },
            { k: 'sas_io', l: 'SAS IOPS' }, { k: 'sas_mb', l: 'SAS MB/s' } ] },
        { label: 'System', metrics: [
            { k: 'cpu_pc', l: 'CPU', u: '%' },
            { k: 'compression_cpu_pc', l: 'Compression CPU', u: '%' },
            { k: 'total_cache_pc', l: 'Cache', u: '%' },
            { k: 'write_cache_pc', l: 'Write cache', u: '%' },
            { k: 'power_w', l: 'Power', u: 'W' }, { k: 'temp_c', l: 'Temperature', u: 'C' } ] },
    ],

    // Inline SVG — no library, no external fetch (the GUI is served from the
    // node and a CSP-safe inline element is the whole budget here).
    sparkline: function(values) {
        if (!values || values.length < 2) { return ''; }
        let nums = values.map(Number).filter(function(v) { return isFinite(v); });
        if (nums.length < 2) { return ''; }
        let max = Math.max.apply(null, nums);
        let min = Math.min.apply(null, nums);
        let span = (max - min) || 1;
        let w = 90, hh = 18;
        let step = w / (nums.length - 1);
        let pts = nums.map(function(v, i) {
            return (i * step).toFixed(1) + ',' + (hh - ((v - min) / span) * hh).toFixed(1);
        }).join(' ');
        return `<svg width="${w}" height="${hh}" style="vertical-align:middle;" `
            + `viewBox="0 0 ${w} ${hh}" preserveAspectRatio="none">`
            + `<polyline points="${pts}" fill="none" stroke="#5a9fd4" stroke-width="1.5"/></svg>`;
    },

    renderPerformance: function(d) {
        let me = this;
        let e = Ext.htmlEncode;
        let h = [];
        if (!d || d.error) {
            return '<div style="color:#c0392b;">' + ((d && d.error) || e(gettext('Query failed'))) + '</div>';
        }
        let stats = (d.performance && d.performance.stats) || {};
        let hist = d.history || {};

        let nodeRows = (d.nodes && d.nodes.nodes) || [];
        // Only claim nothing was reported when nothing was. Printing this
        // above a per-canister table full of live numbers reads as a bug in
        // the panel rather than as a partial answer.
        if (!Object.keys(stats).length && !nodeRows.length) {
            h.push(`<div style="color:#888;">${e(gettext('No performance statistics reported.'))}</div>`);
        }

        // Two things the reader has to know to trust these numbers.
        //
        // The unit: IBM's own 8.7 documentation contradicts itself on the
        // *_ms statistics - the stat_name descriptions say microseconds, the
        // attribute table reads as milliseconds, and the Performance
        // statistics page says the CLI always shows microseconds. Guessing
        // wrong is a 1000x error, so the raw value is shown unlabelled until
        // it is checked against the array's own GUI.
        let notes = [gettext(
            'Latency is shown as the array reports it. IBM documents these '
            + 'values inconsistently as microseconds or milliseconds - compare '
            + 'once against the array GUI before treating the unit as known.')];
        if (d.performance && d.performance.derived) {
            notes.push(gettext(
                'System totals are derived from per-node statistics: '
                + 'throughput summed across canisters, latency and percentages '
                + 'taken from the busiest one.'));
        }

        me.PERF_GROUPS.forEach(function(g) {
            let rows = g.metrics.filter(function(m) { return stats[m.k] !== undefined; });
            if (!rows.length) { return; }
            h.push(`<div style="margin-top:12px;"><b style="font-size:12px;">${e(gettext(g.label))}</b>`);
            h.push('<table style="font-size:12px;margin-top:2px;"><tbody>');
            rows.forEach(function(m) {
                let s = stats[m.k];
                let unit = m.u ? ' ' + e(m.u) : '';
                h.push('<tr>'
                    + `<td style="padding:1px 14px 1px 0;color:#888;white-space:nowrap;">${e(gettext(m.l))}</td>`
                    + `<td style="padding:1px 14px 1px 0;text-align:right;"><b>`
                        + (s.current === undefined || s.current === null ? '&ndash;' : e(String(s.current)))
                        + `</b>${unit}</td>`
                    + `<td style="padding:1px 14px 1px 0;color:#888;white-space:nowrap;">`
                        + (s.peak === undefined || s.peak === null
                            ? ''
                            : `${e(gettext('peak'))} ${e(String(s.peak))}${unit}`
                              + (s.peak_time ? ` ${e(gettext('at'))} ${me.stamp(s.peak_time)}` : ''))
                    + '</td>'
                    + `<td style="padding:1px 0;">${g.spark ? me.sparkline(hist[m.k]) : ''}</td>`
                    + '</tr>');
            });
            h.push('</tbody></table></div>');
        });

        // Per-canister. An imbalance here is the clearest single signal that
        // one node is the bottleneck rather than the array as a whole.
        let nodes = nodeRows;
        if (nodes.length) {
            h.push(`<div style="margin-top:12px;"><b style="font-size:12px;">${e(gettext('Nodes'))}</b>`);
            h.push('<table style="font-size:12px;margin-top:2px;"><tbody>');
            nodes.forEach(function(n) {
                let st = n.stats || {};
                let cell = function(k, unit) {
                    let v = st[k];
                    return v === undefined || v.current === undefined || v.current === null
                        ? '&ndash;' : e(String(v.current)) + (unit || '');
                };
                h.push('<tr>'
                    + `<td style="padding:1px 14px 1px 0;"><b>${e(n.node)}</b></td>`
                    + `<td style="padding:1px 14px 1px 0;color:#888;">${e(gettext('CPU'))} ${cell('cpu_pc', '%')}</td>`
                    + `<td style="padding:1px 14px 1px 0;color:#888;">${e(gettext('Cache'))} ${cell('total_cache_pc', '%')}</td>`
                    + `<td style="padding:1px 14px 1px 0;color:#888;">${e(gettext('Latency'))} ${cell('vdisk_ms')}</td>`
                    + `<td style="padding:1px 0;color:#888;">${e(gettext('IOPS'))} ${cell('vdisk_io')}</td>`
                    + '</tr>');
            });
            h.push('</tbody></table></div>');
        }

        // Throttles are a CONFIGURED cap, not a symptom — which makes them
        // the one "why is this slow" answer the array can give outright.
        let thr = d.throttles;
        if (thr && thr.total) {
            h.push(`<div style="margin-top:12px;"><b style="font-size:12px;">${e(gettext('Throttles'))}</b>`);
            h.push('<table style="font-size:12px;margin-top:2px;"><tbody>');
            (thr.throttles || []).forEach(function(t) {
                h.push('<tr>'
                    + `<td style="padding:1px 14px 1px 0;">${e(t.object_name || t.throttle_name || '')}</td>`
                    + `<td style="padding:1px 14px 1px 0;color:#888;">${e(t.throttle_type || '')}</td>`
                    + `<td style="padding:1px 14px 1px 0;">`
                        + (t.IOPs_limit ? `${e(String(t.IOPs_limit))} ${e(gettext('IOPS'))}` : '')
                    + '</td>'
                    + `<td style="padding:1px 0;">`
                        + (t.bandwidth_limit_MB ? `${e(String(t.bandwidth_limit_MB))} MB/s` : '')
                    + '</td></tr>');
            });
            h.push('</tbody></table></div>');
        }

        notes.forEach(function(n) {
            h.push(`<div style="margin-top:8px;font-size:11px;color:#888;max-width:640px;">`
                + '<i class="fa fa-info-circle"></i> ' + e(n) + '</div>');
        });

        if (d.errors) {
            h.push(`<div style="margin-top:10px;font-size:12px;color:#c87f0a;">`
                + e(gettext('Sections unavailable')) + ': ' + e(Object.keys(d.errors).join(', ')) + '</div>');
        }
        return h.join('');
    },
});

// ---------------------------------------------------------------------------
// LOCAL PATCH (datacenter overview, see UPSTREAM.md section 3): a "FlashSystem"
// entry in the Datacenter menu beside Ceph, aggregating every flashsystem
// storage in the cluster — array identity, per-pool capacity, which storages
// share each pool, ranked volume/guest consumption, FC ports, unfixed array
// alerts and array performance.
//
// Fed by TWO endpoints per array, /overview and /performance, each
// de-duplicated server-side: one request per array per section, and the array
// itself sees each fact fetched once rather than once per storage. They paint
// into separate targets so a slow statistics call cannot hold up the capacity
// view.
//
// The small formatters are duplicated from the health panel on purpose — that
// panel is validated in production and not worth refactoring for a dozen
// lines. The larger new sections live in PVE.FlashSystemUI above instead.
// ---------------------------------------------------------------------------

Ext.define('PVE.dc.FlashSystemOverview', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveDcFlashSystemOverview',

    scrollable: true,
    layout: 'anchor',

    // Two independent render targets, not one. Capacity and performance are
    // separate endpoints with separate deadlines precisely so a slow
    // lssystemstats cannot delay the pool capacity people came to read — and
    // that only pays off if the panel paints them independently too.
    // anchor:'100%' on both — an anchor layout leaves an unanchored child at
    // its natural width, which for a bare component is its content's width.
    defaults: { xtype: 'component', anchor: '100%' },
    items: [
        { itemId: 'caps', padding: '15 15 0 15',
          html: '<div>' + gettext('Loading...') + '</div>' },
        { itemId: 'perf', padding: 15, html: '' },
    ],

    tbar: [
        {
            text: gettext('Refresh'),
            iconCls: 'fa fa-refresh',
            handler: function() {
                this.up('panel').reload();
            },
        },
    ],

    esc: Ext.htmlEncode,

    fmtBytes: function(v) {
        if (v === undefined || v === null) { return '-'; }
        return Proxmox.Utils.format_size(v);
    },

    fmtEventTime: function(t) {
        let m = /^(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})$/.exec(String(t || ''));
        if (!m) { return t || ''; }
        return `20${m[1]}-${m[2]}-${m[3]} ${m[4]}:${m[5]}:${m[6]}`;
    },

    setHtml: function(itemId, html) {
        let c = this.down('#' + itemId);
        if (c) { c.update(html); }
    },

    // Any online node will do — the endpoint is proxied to it and the data is
    // array-wide, not node-specific.
    anyNode: function() {
        let found;
        try {
            PVE.data.ResourceStore.each(function(rec) {
                if (!found && rec.data.type === 'node' && rec.data.status === 'online') {
                    found = rec.data.node;
                }
                return !found;
            });
        } catch (err) {
            // ignore — fall through to the Proxmox global below
        }
        if (!found && typeof Proxmox !== 'undefined' && Proxmox.NodeName
            && Proxmox.NodeName !== 'localhost') {
            found = Proxmox.NodeName;
        }
        return found;
    },

    renderArray: function(d, arrIdx) {
        let me = this;
        let e = me.esc;
        let h = [];
        if (!d || d.error) {
            // d.error is response.htmlStatus, already encoded by the toolkit.
            return '<div style="color:#c0392b;margin-bottom:18px;">'
                + ((d && d.error) || e(gettext('Query failed'))) + '</div>';
        }
        let sys = d.system || {};

        h.push('<div style="margin-bottom:22px;">');
        h.push(`<h2 style="margin:0 0 2px;font-size:16px;">${e(sys.name || d.array || 'FlashSystem')}</h2>`);
        let sub = [];
        if (sys.product_name) { sub.push(e(sys.product_name)); }
        if (sys.code_level) { sub.push(e(gettext('Firmware')) + ' ' + e(sys.code_level)); }
        if (d.array) { sub.push(e(d.array)); }
        h.push(`<div style="color:#888;margin-bottom:12px;">${sub.join(' &middot; ')}</div>`);

        // ports + alerts, one line each — array-wide facts
        if (d.ports) {
            let ok = d.ports.active === d.ports.total;
            h.push(`<div style="margin-bottom:4px;">`
                + (ok ? '<i class="fa fa-check" style="color:#2d7d46;"></i> '
                      : '<i class="fa fa-exclamation-triangle" style="color:#c87f0a;"></i> ')
                + `${d.ports.active} / ${d.ports.total} ${e(gettext('FC ports active'))}</div>`);
        }
        if (d.events) {
            let alerts = d.events.alerts || 0;
            h.push('<div style="margin-bottom:10px;">'
                + (alerts === 0
                    ? '<i class="fa fa-check" style="color:#2d7d46;"></i> ' + e(gettext('No unfixed alerts'))
                    : `<i class="fa fa-exclamation-triangle" style="color:#c0392b;"></i> <b>${alerts}</b> ${e(gettext('unfixed alerts'))}`)
                // Only shown when the whole unfixed log was fetched. Under the
                // server-side alert filter the informational events are not in
                // the payload, and printing 0 would claim there are none.
                + (d.events.unfixed_total === undefined
                    ? ''
                    : ` <span style="color:#888;">(${d.events.unfixed_total} ${e(gettext('events array-wide, incl. informational'))})</span>`)
                + '</div>');
            (d.events.recent || []).forEach(function(ev) {
                h.push('<div style="font-size:12px;color:#888;margin-left:18px;">'
                    + `${e(me.fmtEventTime(ev.last_timestamp))} &nbsp; <b>${e(ev.error_code || '')}</b> `
                    + `${e(ev.description || '')}`
                    + (ev.object_name ? ` (${e(ev.object_name)})` : '') + '</div>');
            });
        }

        // one card per pool, listing the storages that share it
        (d.pools || []).forEach(function(p, poolIdx) {
            let c = p.capacity || {};
            let known = c.provision_total !== undefined;
            let pct = known ? (c.provision_used_pct || 0) : 0;
            let color = pct >= 90 ? '#c0392b' : (pct >= 75 ? '#c87f0a' : '#2d7d46');
            h.push('<div style="margin-top:16px;padding:10px 12px;border:1px solid #444;border-radius:4px;">');
            h.push(`<div style="display:flex;justify-content:space-between;margin-bottom:6px;">`
                + `<b>${e(p.pool || '')}</b>`
                + `<span style="color:#888;">`
                + (known ? `${pct}% ${e(gettext('of physical'))}` : e(gettext('unavailable')))
                + (c.data_reduction === 'yes' ? ' &middot; ' + e(gettext('data reduction')) : '')
                + `</span></div>`);
            h.push(`<div style="max-width:520px;background:#2a2a2a;border:1px solid #555;border-radius:3px;height:14px;">`
                + `<div style="background:${color};width:${Math.min(pct, 100)}%;height:100%;border-radius:2px;"></div></div>`);
            h.push(`<div style="color:#888;font-size:12px;margin:4px 0 8px;">`
                + (c.provision_total === undefined
                    ? '<i class="fa fa-question-circle"></i> ' + e(gettext('capacity unavailable'))
                    : `${me.fmtBytes(c.provision_used)} / ${me.fmtBytes(c.provision_total)} `
                      + `(${me.fmtBytes(c.provision_free)} ${e(gettext('free'))})`)
                + ' &middot; '
                + (p.pool_volumes === undefined
                    ? e(gettext('volume count unavailable'))
                    : `${p.pool_volumes} ${e(gettext('volumes in pool'))}`)
                + '</div>');
            h.push('<table style="font-size:12px;width:100%;">');
            (p.storages || []).forEach(function(s) {
                h.push('<tr>'
                    + `<td style="padding:1px 12px 1px 0;"><b>${e(s.storage)}</b></td>`
                    + `<td style="padding:1px 12px 1px 0;color:#888;">`
                        + (s.prefix ? e(s.prefix)
                            : '<i class="fa fa-exclamation-triangle" style="color:#c87f0a;"></i> ' + e(gettext('no prefix')))
                    + '</td>'
                    + `<td style="padding:1px 12px 1px 0;">`
                        + (s.volumes === undefined ? '&ndash;' : `${Number(s.volumes) || 0} ${e(gettext('vols'))}`)
                    + '</td>'
                    + `<td style="padding:1px 12px 1px 0;">`
                        + (s.provisioned === undefined ? '&ndash;' : me.fmtBytes(s.provisioned))
                    + '</td>'
                    + `<td style="padding:1px 0;color:#888;">`
                        + (s.thin ? e(gettext('thin')) : e(gettext('thick')))
                        + (s.snapshots ? ' &middot; ' + e(gettext('snapshots')) : '')
                    + '</td></tr>');
            });
            h.push('</table>');

            // Ranked consumers — what is actually occupying this pool.
            if (p.top) {
                let tid = `a${arrIdx}p${poolIdx}`;
                h.push(PVE.FlashSystemUI.renderTop(p.top, tid, (me.sortState || {})[tid]));
            }
            h.push('</div>');
        });

        if (d.errors) {
            h.push(`<div style="margin-top:10px;font-size:12px;color:#c87f0a;">`
                + e(gettext('Sections unavailable')) + ': '
                + e(Object.keys(d.errors).join(', ')) + '</div>');
        }
        h.push('</div>');
        return h.join('');
    },

    renderPerfBlock: function(d, i) {
        let e = this.esc;
        let sys = (d && d.system) || {};
        let title = sys.name || (d && d.array) || `FlashSystem ${i + 1}`;
        return '<div style="margin-bottom:18px;">'
            + `<h2 style="margin:0 0 2px;font-size:16px;">${e(title)} &mdash; ${e(gettext('Performance'))}</h2>`
            + `<div style="color:#888;font-size:12px;margin-bottom:4px;">`
            + e(gettext('Array-wide. Peak values cover the last five minutes.')) + '</div>'
            + PVE.FlashSystemUI.renderPerformance(d)
            + '</div>';
    },

    // Re-render one target from cached data — used both when a fetch lands
    // and when a column header changes the sort.
    repaint: function(which) {
        let me = this;
        let reps = me.fsReps || [];
        if (which === 'caps') {
            let data = me.capsData || [];
            me.setHtml('caps', reps.map(function(_, i) { return me.renderArray(data[i], i); }).join(''));
        } else {
            let data = me.perfData || [];
            me.setHtml('perf', reps.map(function(_, i) { return me.renderPerfBlock(data[i], i); }).join(''));
        }
    },

    // One request per array per section. NB: Proxmox.Utils.API2Request invokes
    // `callback` BEFORE success/failure, so counting down there renders with
    // the data still unassigned — on a single-array cluster that is a
    // permanently blank panel. Count down inside both handlers.
    fanout: function(node, reps, subpath, cacheKey, which) {
        let me = this;
        let out = [];
        let pending = reps.length;
        let done = function() {
            pending--;
            if (pending > 0) { return; }
            me[cacheKey] = out;
            me.repaint(which);
        };
        reps.forEach(function(st, i) {
            Proxmox.Utils.API2Request({
                url: `/nodes/${node}/flashsystem/${encodeURIComponent(st)}/${subpath}`,
                method: 'GET',
                success: function(r) { out[i] = r.result.data; done(); },
                failure: function(r) { out[i] = { error: r.htmlStatus }; done(); },
            });
        });
    },

    reload: function() {
        let me = this;
        let node = me.anyNode();
        if (!node) {
            me.setHtml('caps', '<div>' + gettext('No online node found.') + '</div>');
            me.setHtml('perf', '');
            return;
        }
        Proxmox.Utils.API2Request({
            url: `/nodes/${node}/flashsystem`,
            method: 'GET',
            waitMsgTarget: me,
            failure: function(response) {
                me.setHtml('caps', '<div style="color:#c0392b;">'
                    + (response.htmlStatus || Ext.htmlEncode(gettext('Query failed'))) + '</div>');
                me.setHtml('perf', '');
            },
            success: function(response) {
                let list = response.result.data || [];
                if (!list.length) {
                    me.setHtml('caps', '<div>' + gettext('No FlashSystem storages are configured.') + '</div>');
                    me.setHtml('perf', '');
                    return;
                }
                // One representative storage per array: both endpoints are
                // array-wide, so querying every storage would repeat itself.
                let seen = Object.create(null);
                let reps = [];
                list.forEach(function(s) {
                    let key = s.address || '_';
                    if (!seen[key]) { seen[key] = true; reps.push(s.storage); }
                });
                me.fsReps = reps;
                me.setHtml('perf', '<div>' + gettext('Loading...') + '</div>');
                me.fanout(node, reps, 'overview', 'capsData', 'caps');
                me.fanout(node, reps, 'performance', 'perfData', 'perf');
            },
        });
    },

    listeners: {
        activate: function() {
            this.reload();
        },
        // Delegated so the tables stay plain HTML. Sorting is a convenience:
        // the server already returns highest-first, so a handler that never
        // fires costs nothing.
        click: {
            element: 'body',
            fn: function(ev) {
                let me = this;
                let el = ev.getTarget('[data-fssort]', 6);
                if (!el) { return; }
                let key = el.getAttribute('data-fssort');
                let tid = el.getAttribute('data-fstable');
                if (!key || !tid) { return; }
                me.sortState = me.sortState || {};
                let cur = me.sortState[tid];
                me.sortState[tid] = (cur && cur.key === key)
                    ? { key: key, dir: cur.dir === 'asc' ? 'desc' : 'asc' }
                    : { key: key, dir: 'desc' };
                me.repaint('caps');
            },
        },
    },
});
