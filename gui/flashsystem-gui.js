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

        if (d.events) {
            // Alerts only. The array's unfixed log is mostly informational
            // chatter (copy-format notices, SAS discovery) — showing that raw
            // count would bury a real pool-space warning under four figures.
            let alerts = d.events.alerts || 0;
            let total = d.events.unfixed_total || 0;
            h.push(head(gettext('Array alerts')));
            h.push('<div>'
                + (alerts === 0
                    ? '<i class="fa fa-check" style="color:#2d7d46;"></i> ' + e(gettext('No unfixed alerts'))
                    : `<i class="fa fa-exclamation-triangle" style="color:#c0392b;"></i> <b>${alerts}</b> ${e(gettext('unfixed'))}`)
                + ` <span style="color:#888;">(${total} ${e(gettext('unfixed events array-wide, incl. informational'))})</span></div>`);
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
                me.update(me.renderHealth(response.result.data || {}));
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
// LOCAL PATCH (datacenter overview, see UPSTREAM.md section 3): a "FlashSystem"
// entry in the Datacenter menu beside Ceph, aggregating every flashsystem
// storage in the cluster — array identity, per-pool capacity, which storages
// share each pool, FC ports and unfixed array alerts.
//
// Fed by GET /nodes/{node}/flashsystem/{storage}/overview, which de-duplicates
// server-side: ONE request per array, and the array itself sees each fact
// fetched once rather than once per storage.
//
// The small formatters are duplicated from the health panel on purpose — that
// panel is validated in production and not worth refactoring for a dozen lines.
// ---------------------------------------------------------------------------

Ext.define('PVE.dc.FlashSystemOverview', {
    extend: 'Ext.panel.Panel',
    alias: 'widget.pveDcFlashSystemOverview',

    scrollable: true,
    bodyPadding: 15,
    html: '<div>' + gettext('Loading...') + '</div>',

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

    renderArray: function(d) {
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
                + ` <span style="color:#888;">(${d.events.unfixed_total || 0} ${e(gettext('events array-wide, incl. informational'))})</span></div>`);
            (d.events.recent || []).forEach(function(ev) {
                h.push('<div style="font-size:12px;color:#888;margin-left:18px;">'
                    + `${e(me.fmtEventTime(ev.last_timestamp))} &nbsp; <b>${e(ev.error_code || '')}</b> `
                    + `${e(ev.description || '')}`
                    + (ev.object_name ? ` (${e(ev.object_name)})` : '') + '</div>');
            });
        }

        // one card per pool, listing the storages that share it
        (d.pools || []).forEach(function(p) {
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
            h.push('</table></div>');
        });

        if (d.errors) {
            h.push(`<div style="margin-top:10px;font-size:12px;color:#c87f0a;">`
                + e(gettext('Sections unavailable')) + ': '
                + e(Object.keys(d.errors).join(', ')) + '</div>');
        }
        h.push('</div>');
        return h.join('');
    },

    reload: function() {
        let me = this;
        let node = me.anyNode();
        if (!node) {
            me.update('<div>' + gettext('No online node found.') + '</div>');
            return;
        }
        Proxmox.Utils.API2Request({
            url: `/nodes/${node}/flashsystem`,
            method: 'GET',
            waitMsgTarget: me,
            failure: function(response) {
                me.update('<div style="color:#c0392b;">'
                    + (response.htmlStatus || Ext.htmlEncode(gettext('Query failed'))) + '</div>');
            },
            success: function(response) {
                let list = response.result.data || [];
                if (!list.length) {
                    me.update('<div>' + gettext('No FlashSystem storages are configured.') + '</div>');
                    return;
                }
                // One representative storage per array: the overview is
                // array-wide, so querying every storage would repeat itself.
                let seen = Object.create(null);
                let reps = [];
                list.forEach(function(s) {
                    let key = s.address || '_';
                    if (!seen[key]) { seen[key] = true; reps.push(s.storage); }
                });
                // NB: Proxmox.Utils.API2Request invokes `callback` BEFORE
                // success/failure, so counting down there renders with the
                // data still unassigned — on a single-array cluster that is a
                // permanently blank panel. Count down inside both handlers.
                let out = [];
                let pending = reps.length;
                let done = function() {
                    pending--;
                    if (pending > 0) { return; }
                    // Map over reps, not out: a sparse array would silently
                    // drop an entry rather than showing its error.
                    me.update(reps.map(function(_, i) { return me.renderArray(out[i]); }).join(''));
                };
                reps.forEach(function(st, i) {
                    Proxmox.Utils.API2Request({
                        url: `/nodes/${node}/flashsystem/${encodeURIComponent(st)}/overview`,
                        method: 'GET',
                        success: function(r) { out[i] = r.result.data; done(); },
                        failure: function(r) { out[i] = { error: r.htmlStatus }; done(); },
                    });
                });
            },
        });
    },

    listeners: {
        activate: function() {
            this.reload();
        },
    },
});

