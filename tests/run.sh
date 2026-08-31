#!/bin/sh
# Syntax-check and unit-test the FlashSystem plugin.
# Runs anywhere perl exists — PVE's modules are stubbed in ./stub.
# Dual-home: works from a vendored layout (module in ../files/)
# and from the standalone repo (module in ../).
set -eu
cd "$(dirname "$0")"
MOD=../files/FlashSystemPlugin.pm
[ -f "$MOD" ] || MOD=../FlashSystemPlugin.pm
GUI=../files/flashsystem-gui.js
[ -f "$GUI" ] || GUI=../gui/flashsystem-gui.js
perl -I stub -c "$MOD"
perl t_prefix.pl
perl t_status.pl
perl t_names.pl
perl t_resize.pl
perl t_api.pl

# The GUI render helpers, executed against fixtures with a stubbed ExtJS.
# Two of the six defects found in review were renderer-only - data the API
# computed and returned that nothing ever displayed - which no Perl test can
# see. Skipped rather than failed where node is unavailable: this must not
# block a plain Ansible run on a host without it.
if command -v node >/dev/null 2>&1; then
    node --check "$GUI" && node t_gui.js
else
    echo "t_gui.js  SKIPPED (node not installed)"
fi
