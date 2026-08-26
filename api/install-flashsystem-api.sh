#!/bin/sh
# ---------------------------------------------------------------------------
# Register the FlashSystem health API into the Proxmox API tree.
#
# Proxmox has no API plugin registry, so PVE::API2::FlashSystem is hooked in
# by appending a marker-wrapped registration block to PVE/API2/Nodes.pm
# (executed at module load — appending after the trailing `1;` works because
# require evaluates the whole file). pve-manager upgrades REWRITE Nodes.pm,
# so an APT post-invoke hook re-applies the block afterwards.
#
# The re-apply logic lives in a SHIPPED SCRIPT (/usr/local/sbin/
# flashsystem-api-reapply) that the APT hook merely invokes: apt.conf values
# cannot contain backslashes or embedded quotes, so the logic must not be
# inlined there — and the re-apply path needs the same verify-and-rollback
# plus daemon reload the first install gets, because a blind append against a
# future incompatible Nodes.pm would take down pvedaemon/pveproxy at their
# next start. The re-apply script always exits 0 (it must never break apt);
# failures go to syslog (tag: flashsystem-api).
#
# Run this on EVERY node. Requires FlashSystemAPI.pm in this directory.
#
# Usage:  ./install-flashsystem-api.sh   (from this directory, as root)
# Remove: ./install-flashsystem-api.sh --uninstall
# ---------------------------------------------------------------------------
set -eu

SRC_LOCAL="FlashSystemAPI.pm"
MODULE="/usr/share/perl5/PVE/API2/FlashSystem.pm"
NODES="/usr/share/perl5/PVE/API2/Nodes.pm"
SNIPPET="/usr/local/share/flashsystem/nodes-registration.pm"
REAPPLY="/usr/local/sbin/flashsystem-api-reapply"
HOOK="/etc/apt/apt.conf.d/81flashsystem-api"

strip_block() {
    [ -f "$NODES" ] || return 0
    sed -i '/^# >>> flashsystem-api BEGIN$/,/^# <<< flashsystem-api END$/d' "$NODES"
}

if [ "${1:-}" = "--uninstall" ]; then
    strip_block
    rm -f "$HOOK" "$REAPPLY" "$SNIPPET" "$MODULE" "$NODES.flashsystem-pre"
    systemctl reload-or-restart pvedaemon pveproxy
    echo "Removed FlashSystem health API."
    exit 0
fi

[ -f "$SRC_LOCAL" ] || { echo "error: run from the plugin directory ($SRC_LOCAL not found)"; exit 1; }
[ -f "$NODES" ] || { echo "error: $NODES not found - is this a Proxmox VE node?"; exit 1; }

install -D -m 0644 "$SRC_LOCAL" "$MODULE"

# The module must load on its own before we wire it into the tree.
perl -e 'require "/usr/share/perl5/PVE/API2/FlashSystem.pm";' \
    || { echo "error: $MODULE does not load - not patching Nodes.pm"; exit 1; }

# The registration block. The REGISTERED guard makes an accidental double
# block degrade to a no-op instead of a fatal duplicate-method error that
# would kill the whole API tree.
install -d -m 0755 "$(dirname "$SNIPPET")"
cat > "$SNIPPET" <<'PERL'
# >>> flashsystem-api BEGIN
if (!$PVE::API2::FlashSystem::REGISTERED++) {
    require PVE::API2::FlashSystem;
    PVE::API2::Nodes::Nodeinfo->register_method ({
        subclass => "PVE::API2::FlashSystem",
        path => 'flashsystem',
    });
}
1;
# <<< flashsystem-api END
PERL

# The re-apply script: strip remnants, back up the CLEAN pre-patch state,
# append, verify the tree still loads (restore on failure), reload daemons.
cat > "$REAPPLY" <<'SH'
#!/bin/sh
# Re-apply the FlashSystem API registration to PVE/API2/Nodes.pm after
# pve-manager upgrades rewrite it. Installed and invoked by
# install-flashsystem-api.sh; also invoked by the APT Post-Invoke hook.
# ALWAYS exits 0 - this runs inside apt and must never break it.
set -u
NODES=/usr/share/perl5/PVE/API2/Nodes.pm
SNIPPET=/usr/local/share/flashsystem/nodes-registration.pm
MODULE=/usr/share/perl5/PVE/API2/FlashSystem.pm
log() { logger -t flashsystem-api "$*" 2>/dev/null || true; echo "flashsystem-api: $*" >&2; }
[ -f "$NODES" ] && [ -f "$SNIPPET" ] && [ -f "$MODULE" ] || exit 0
if grep -qF '# >>> flashsystem-api BEGIN' "$NODES"; then
    exit 0    # already applied
fi
# Strip partial remnants first so the backup is the clean, unpatched state -
# that is what a rollback must restore.
sed -i '/^# >>> flashsystem-api BEGIN$/,/^# <<< flashsystem-api END$/d' "$NODES"
cp -a "$NODES" "$NODES.flashsystem-pre"
cat "$SNIPPET" >> "$NODES"
ERR=$(perl -e 'use PVE::API2::Nodes;' 2>&1) || {
    cp -a "$NODES.flashsystem-pre" "$NODES"
    log "Nodes.pm failed to load with the registration - rolled back: $ERR"
    exit 0
}
systemctl reload-or-restart pvedaemon pveproxy 2>/dev/null \
    || log "daemon reload failed - restart pvedaemon and pveproxy manually"
log "registration re-applied"
exit 0
SH
chmod 0755 "$REAPPLY"

# APT hook: a single quoted string with no embedded quotes or backslashes -
# apt.conf(5) forbids both, and a malformed conf.d file breaks EVERY apt run.
cat > "$HOOK" <<EOF
// Re-apply the FlashSystem health API registration after upgrades.
DPkg::Post-Invoke { "$REAPPLY"; };
EOF

# Belt: prove apt still parses its config with the hook in place.
apt-config dump >/dev/null 2>&1 || {
    rm -f "$HOOK"
    echo "error: apt rejected the hook file - hook removed, apt is unharmed"
    exit 1
}

"$REAPPLY"

# The re-apply script skips the reload when the block was already present,
# but a refreshed MODULE still needs the daemons to pick up new code.
systemctl reload-or-restart pvedaemon pveproxy

echo "Installed FlashSystem health API on $(hostname)."
echo "Try:  pvesh get /nodes/\$(hostname)/flashsystem"
