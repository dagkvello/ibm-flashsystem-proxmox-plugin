#!/bin/sh
# Syntax-check and unit-test the FlashSystem plugin.
# Runs anywhere perl exists — PVE's modules are stubbed in ./stub.
# Dual-home: works from a vendored layout (module in ../files/)
# and from the standalone repo (module in ../).
set -eu
cd "$(dirname "$0")"
MOD=../files/FlashSystemPlugin.pm
[ -f "$MOD" ] || MOD=../FlashSystemPlugin.pm
perl -I stub -c "$MOD"
perl t_prefix.pl
perl t_status.pl
perl t_names.pl
perl t_api.pl
