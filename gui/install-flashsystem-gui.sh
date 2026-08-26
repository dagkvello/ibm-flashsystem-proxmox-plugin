#!/bin/sh
# ---------------------------------------------------------------------------
# Install the FlashSystem storage GUI extension into pve-manager.
#
# Proxmox has no frontend plugin API, so we append flashsystem-gui.js to
# pvemanagerlib.js to get "Add"/"Edit" dialogs for the custom `flashsystem`
# storage type. pve-manager upgrades REWRITE that file, so we also install an
# APT post-invoke hook that re-appends the snippet automatically afterwards.
#
# Run this on EVERY node (it is a per-host frontend patch, not cluster config).
# Re-run after editing flashsystem-gui.js to refresh the installed copy.
#
# Usage:  ./install-flashsystem-gui.sh   (from this directory, as root)
# Remove: ./install-flashsystem-gui.sh --uninstall
# ---------------------------------------------------------------------------
set -eu

SRC_LOCAL="flashsystem-gui.js"
SNIPPET="/usr/local/share/flashsystem/flashsystem-gui.js"
LIB="/usr/share/pve-manager/js/pvemanagerlib.js"
HOOK="/etc/apt/apt.conf.d/80flashsystem-gui"
MARKER="PVE.storage.FlashSystemInputPanel"
BEGIN="// >>> flashsystem-gui BEGIN"
END="// <<< flashsystem-gui END"

strip_block() {
    # Remove any previously appended block (between the BEGIN/END markers).
    [ -f "$LIB" ] || return 0
    if grep -qF "$BEGIN" "$LIB"; then
        sed -i "/$(printf '%s' "$BEGIN" | sed 's/[[\.*^$/]/\\&/g')/,/$(printf '%s' "$END" | sed 's/[[\.*^$/]/\\&/g')/d" "$LIB"
    fi
}

if [ "${1:-}" = "--uninstall" ]; then
    strip_block
    rm -f "$HOOK" "$SNIPPET"
    systemctl reload-or-restart pveproxy
    echo "Removed FlashSystem GUI extension. RESTART the browser as a process - a hard refresh is not enough."
    exit 0
fi

[ -f "$SRC_LOCAL" ] || { echo "error: run from the plugin directory ($SRC_LOCAL not found)"; exit 1; }
[ -f "$LIB" ] || { echo "error: $LIB not found - is this a Proxmox VE node?"; exit 1; }

# Keep a copy the APT hook can re-apply from.
install -D -m 0644 "$SRC_LOCAL" "$SNIPPET"

# (Re)append the snippet, wrapped in markers so it can be cleanly replaced.
strip_block
{
    echo "$BEGIN"
    cat "$SNIPPET"
    echo "$END"
} >> "$LIB"

# APT hook: after any pve-manager upgrade rewrites the lib, re-append if missing.
cat > "$HOOK" <<EOF
// Re-apply the FlashSystem storage GUI extension after upgrades.
DPkg::Post-Invoke {
    "if [ -f $SNIPPET ] && [ -f $LIB ] && ! grep -q '$MARKER' $LIB; then { echo '$BEGIN'; cat $SNIPPET; echo '$END'; } >> $LIB; fi";
};
EOF

systemctl reload-or-restart pveproxy
echo "Installed FlashSystem GUI extension on $(hostname)."
echo "RESTART the browser as a process (a hard refresh is NOT enough - consoles inherit stale JS), then open Datacenter > Storage > Add > IBM FlashSystem."
