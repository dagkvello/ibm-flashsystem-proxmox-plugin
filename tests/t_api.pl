#!/usr/bin/env perl
#
# Unit tests for PVE::API2::FlashSystem — the health & capacity API
# (see UPSTREAM.md section 3). PVE's framework is stubbed; the pure view
# helpers are exercised with fixtures, and the registered API surface is
# asserted through the RESTHandler stub.
#
# Run:  run.sh in this directory

use strict; use warnings;
use FindBin;
use lib "$FindBin::Bin/stub";

# The plugin must load first (the API module reuses its helpers).
# Dual-home: ../files/ in a vendored layout, ../ in the standalone repo.
my ($PLUGIN) = grep { -f } ("$FindBin::Bin/../files/FlashSystemPlugin.pm",
                            "$FindBin::Bin/../FlashSystemPlugin.pm");
require $PLUGIN;
my ($API) = grep { -f } ("$FindBin::Bin/../files/FlashSystemAPI.pm",
                         "$FindBin::Bin/../api/FlashSystemAPI.pm");
require $API;

my $M = 'PVE::API2::FlashSystem';

my $fail = 0;
sub ok_case {
    my ($name, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && $got eq $want);
    printf "%-34s %-30s %s\n", $name, (defined $got ? $got : '(undef)'),
        $ok ? 'ok' : 'FAIL want=' . (defined $want ? $want : '(undef)');
    $fail++ if !$ok;
}

# ---- registered API surface -------------------------------------------------
my $reg = PVE::RESTHandler::registered($M);
ok_case('methods registered', scalar(@$reg), 3);
my ($health) = grep { $_->{name} eq 'health' } @$reg;
ok_case('health exists', ($health ? 'yes' : 'no'), 'yes');
# protected: the handler reads root-only /etc/pve/priv — must run in pvedaemon.
ok_case('health is protected', ($health && $health->{protected} ? 1 : 0), 1);
ok_case('health proxied to node', ($health && $health->{proxyto} // ''), 'node');
ok_case('health has perm check',
    ($health && $health->{permissions} && $health->{permissions}->{check} ? 'yes' : 'no'), 'yes');

# ---- _whitelist --------------------------------------------------------------
my $wl = PVE::API2::FlashSystem::_whitelist({ a => 1, b => undef, c => 3 }, qw(a b));
ok_case('whitelist keeps listed', $wl->{a}, 1);
ok_case('whitelist drops undef', (exists $wl->{b} ? 'yes' : 'no'), 'no');
ok_case('whitelist drops unlisted', (exists $wl->{c} ? 'yes' : 'no'), 'no');

# ---- _pool_view (real Pool0_Gold DRP fixture, same as t_status.pl) -----------
my $drp = {
    name => 'Pool0_Gold', status => 'online', data_reduction => 'yes',
    capacity                => '65120294141952',
    free_capacity           => '48911087566848',
    used_capacity           => '15124972175360',
    physical_capacity       => '14020451500032',
    physical_free_capacity  => '4550058049536',
};
my $pv = PVE::API2::FlashSystem::_pool_view($drp);
ok_case('pool: provision total = physical', $pv->{provision_total}, 14020451500032);
ok_case('pool: provision free  = physical', $pv->{provision_free},  4550058049536);
ok_case('pool: used pct rounded', $pv->{provision_used_pct}, 68);
ok_case('pool: reduction flag kept', $pv->{data_reduction}, 'yes');

# ---- _volumes_view ------------------------------------------------------------
my $scfg = { fsprefix => 'pmcl01' };
my $vols = PVE::API2::FlashSystem::_volumes_view([
    { name => 'pmcl01-vm-1-disk-0',  capacity => '100' },
    { name => 'other-vm-1-disk-0',   capacity => '50'  },   # foreign prefix
    { name => 'pmcl01-vm-2-state-x', capacity => '25'  },
], $scfg);
ok_case('volumes: pool total', $vols->{pool_total}, 3);
ok_case('volumes: ours only', $vols->{ours}, 2);
ok_case('volumes: ours bytes', $vols->{ours_provisioned}, 125);

# ---- _events_view -------------------------------------------------------------
my $ev = PVE::API2::FlashSystem::_events_view([
    { sequence_number => 5, error_code => 'E1', description => 'old',   secret => 'x' },
    { sequence_number => 9, error_code => 'E3', description => 'newest' },
    { sequence_number => 7, error_code => 'E2', description => 'mid' },
], 2);
ok_case('events: unfixed count', $ev->{unfixed}, 3);
ok_case('events: capped', scalar(@{ $ev->{recent} }), 2);
ok_case('events: newest first', $ev->{recent}[0]{error_code}, 'E3');
ok_case('events: unknown keys dropped',
    (exists $ev->{recent}[1]{secret} ? 'yes' : 'no'), 'no');

# ---- _ports_view --------------------------------------------------------------
my $pp = PVE::API2::FlashSystem::_ports_view([
    { id => 1, status => 'active' },
    { id => 2, status => 'active' },
    { id => 3, status => 'inactive_unconfigured' },
]);
ok_case('ports: total', $pp->{total}, 3);
ok_case('ports: active', $pp->{active}, 2);
ok_case('ports: status buckets', $pp->{by_status}{inactive_unconfigured}, 1);

# ---- _budget (shared deadline: min(cap, remaining), floor 0) -----------------
my $now = time();
ok_case('budget: cap wins',      PVE::API2::FlashSystem::_budget($now + 100, 8), 8);
ok_case('budget: remaining wins', (PVE::API2::FlashSystem::_budget($now + 3, 8) <= 3
                                   && PVE::API2::FlashSystem::_budget($now + 3, 8) >= 2) ? 'in-range' : 'out', 'in-range');
ok_case('budget: exhausted -> 0', PVE::API2::FlashSystem::_budget($now - 1, 8), 0);

# ---- _system_view -------------------------------------------------------------
my $sv = PVE::API2::FlashSystem::_system_view(
    { name => 'demo', code_level => '8.7.0.0', console_IP => '192.0.2.1:443' });
ok_case('system: name kept', $sv->{name}, 'demo');
ok_case('system: IPs dropped', (exists $sv->{console_IP} ? 'yes' : 'no'), 'no');

print $fail ? "\n$fail FAILURE(S)\n" : "\nall api cases pass\n";
exit($fail ? 1 : 0);
