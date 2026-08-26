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
