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
            h.push('</table>');
        }

        if (d.ports) {
            let ok = d.ports.active === d.ports.total;
            h.push(head(gettext('FC ports')));
            h.push(`<div>${ok ? '' : '<i class="fa fa-exclamation-triangle" style="color:#c87f0a;"></i> '}`
                + `${d.ports.active} / ${d.ports.total} ${e(gettext('active'))}</div>`);
        }

        if (d.events) {
            h.push(head(gettext('Unfixed events') + `: ${d.events.unfixed}`));
            if (d.events.unfixed > 0 && d.events.recent && d.events.recent.length) {
                h.push('<table style="font-size:12px;">');
                d.events.recent.forEach(ev => {
                    h.push(row(ev.last_timestamp || ev.sequence_number || '',
                        `${e(ev.error_code || '')} ${e(ev.description || '')}`
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
            if (sel.type === 'storage' && sel.plugintype === 'flashsystem' && Ext.isArray(me.items)) {
                me.items.push({
                    xtype: 'pveFlashSystemHealthPanel',
                    title: 'FlashSystem',
                    itemId: 'flashsystemhealth',
                    iconCls: 'fa fa-heartbeat',
                    nodename: sel.node,
                    storage: sel.storage,
                });
            }
        } catch (err) {
            // eslint-disable-next-line no-console
            console.error('flashsystem health tab:', err);
        }
        me.callParent();
    },
});
