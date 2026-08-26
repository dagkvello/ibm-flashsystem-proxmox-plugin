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
ok_case('registered method set',
    join(',', sort map { $_->{name} } @$reg), 'diridx,health,index,overview');
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
    { name => 'pmcl01-tierlun-00',   capacity => '999' },   # ours, not a PVE volume
], $scfg);
ok_case('volumes: pool total', $vols->{pool_total}, 4);
ok_case('volumes: ours only', $vols->{ours}, 2);
ok_case('volumes: ours bytes', $vols->{ours_provisioned}, 125);

# A storage with NO fsprefix: the translation is a pass-through, so the shape
# test is the only thing keeping other consumers' volumes out of the count.
# Live 2026-08-26 this reported 6 volumes / 5.6 TB where PVE managed 4 / 103 GB.
my $noprefix = PVE::API2::FlashSystem::_volumes_view([
    { name => 'vm-102-disk-0',        capacity => '34359738368' },
    { name => 'vm-102-state-test',    capacity => '34808528896' },
    { name => 'pmcl01-vm-196-disk-0', capacity => '34359738368' },   # another storage's
    { name => 'volume-9f3a-openstack', capacity => '2750000000000' }, # not PVE at all
], {});
ok_case('volumes: prefixless PVE shapes only', $noprefix->{ours}, 2);
ok_case('volumes: prefixless pool total', $noprefix->{pool_total}, 4);
ok_case('volumes: prefixless bytes', $noprefix->{ours_provisioned}, 69168267264);

# ---- _events_view -------------------------------------------------------------
# Shapes taken verbatim from a live 8.7.0.3 array (FlashSystem 5200): the
# `fixed=no` query returned 1317 rows, of which exactly one carried an error
# code. Informational rows have error_code "" — they must be counted but
# never listed, or a real pool-space warning hides behind copy-format noise.
my $ev = PVE::API2::FlashSystem::_events_view([
    { sequence_number => '1569', error_code => '1867',
      description => 'Data reduction pool space warning',
      object_type => 'mdiskgrp', object_name => 'Pool1_Silver',
      last_timestamp => '260826031438', secret => 'x' },
    { sequence_number => '1568', error_code => '',
      description => 'SAS discovery occurred, configuration changes complete' },
    { sequence_number => '1565', error_code => '',
      description => 'Virtual Disk Copy Format Completed' },
    { sequence_number => '1400', error_code => '0',
      description => 'zero code is informational, not an alert' },
]);
ok_case('events: alerts only', $ev->{alerts}, 1);
ok_case('events: total counted', $ev->{unfixed_total}, 4);
ok_case('events: alert listed', $ev->{recent}[0]{error_code}, '1867');
ok_case('events: object name kept', $ev->{recent}[0]{object_name}, 'Pool1_Silver');
ok_case('events: informational not listed', scalar(@{ $ev->{recent} }), 1);
ok_case('events: unknown keys dropped',
    (exists $ev->{recent}[0]{secret} ? 'yes' : 'no'), 'no');

# All-informational log: zero alerts, empty list, total still reported.
my $quiet = PVE::API2::FlashSystem::_events_view([
    { sequence_number => '2', error_code => '', description => 'chatter' },
    { sequence_number => '1', description => 'no error_code key at all' },
]);
ok_case('events: quiet array = 0 alerts', $quiet->{alerts}, 0);
ok_case('events: quiet recent empty', scalar(@{ $quiet->{recent} }), 0);
ok_case('events: quiet total kept', $quiet->{unfixed_total}, 2);

# Newest-first ordering and the cap apply to alerts.
my $many = PVE::API2::FlashSystem::_events_view([
    { sequence_number => '10', error_code => '1867', description => 'a' },
    { sequence_number => '30', error_code => '1400', description => 'c' },
    { sequence_number => '20', error_code => '2030', description => 'b' },
], 2);
ok_case('events: alerts capped', scalar(@{ $many->{recent} }), 2);
ok_case('events: alerts newest first', $many->{recent}[0]{sequence_number}, '30');

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

# ---- overview: registered surface + peer/pool grouping ----------------------
# The datacenter panel calls ONE overview per array. Its value is the
# de-duplication: array facts once, each pool once, however many storages
# share it. Here we assert the registered method and the shape of the
# per-pool storage breakdown (the REST fan-out itself needs an array).
my ($ov) = grep { $_->{name} eq 'overview' } @$reg;
ok_case('overview registered', ($ov ? 'yes' : 'no'), 'yes');
ok_case('overview is protected', ($ov && $ov->{protected} ? 1 : 0), 1);
ok_case('overview path', ($ov && $ov->{path} // ''), '{storage}/overview');
ok_case('overview has perm check',
    ($ov && $ov->{permissions} && $ov->{permissions}->{check} ? 'yes' : 'no'), 'yes');

# index must expose the array address, or the panel cannot group by array
# and would issue one overview request per storage instead of per array.
my ($ix) = grep { $_->{name} eq 'index' } @$reg;
ok_case('index returns address',
    ($ix && $ix->{returns}{items}{properties}{address} ? 'yes' : 'no'), 'yes');

# Two storages sharing one pool, counted from a SINGLE lsvdisk result by
# each storage's own prefix — the saving the endpoint exists for.
my $shared = [
    { name => 'pmcl01_Gold-vm-1-disk-0', capacity => '100' },
    { name => 'k8sg-vm-9999-pvc-abc',    capacity => '50'  },
    { name => 'foreign-vm-1-disk-0',     capacity => '999' },
];
my $tier = PVE::API2::FlashSystem::_volumes_view($shared, { fsprefix => 'pmcl01_Gold' });
my $k8s  = PVE::API2::FlashSystem::_volumes_view($shared, { fsprefix => 'k8sg' });
ok_case('overview: tier storage sees its own', $tier->{ours}, 1);
ok_case('overview: k8s storage sees its own', $k8s->{ours}, 1);
ok_case('overview: neither sees the foreign one',
    ($tier->{ours} + $k8s->{ours} + 1), scalar(@$shared));

# ---- overview degradation: a failed section must never publish zeros --------
# The whole point of the panel is capacity truth. "0 volumes in pool" beside a
# real capacity bar reads as an empty pool, not as a failed query — so a
# section that errored must omit its fields, not zero them.
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($scfg, $command) = @_;
        die "lsvdisk exploded\n" if $command eq 'lsvdisk';
        return [] if $command eq 'lseventlog' || $command eq 'lsportfc';
        return { name => 'demo', code_level => '8.7.0.3' } if $command eq 'lssystem';
        return {
            name => 'P1', status => 'online',
            capacity => '100', free_capacity => '40',
            physical_capacity => '100', physical_free_capacity => '40',
        };
    };
    my $degraded = PVE::API2::FlashSystem::_collect_overview(
        'S', { fsaddress => 'a', fspool => 'P1' },
        [ [ 'S', { fsaddress => 'a', fspool => 'P1', fsprefix => 'p' } ] ]);
    my $pool = $degraded->{pools}[0];
    ok_case('degrade: volume count omitted',
        (exists $pool->{pool_volumes} ? 'reported-as-zero' : 'omitted'), 'omitted');
    ok_case('degrade: storage volumes omitted',
        (exists $pool->{storages}[0]{volumes} ? 'reported-as-zero' : 'omitted'), 'omitted');
    ok_case('degrade: storage identity kept',
        $pool->{storages}[0]{prefix}, 'p');
    ok_case('degrade: capacity still reported',
        ($pool->{capacity} && $pool->{capacity}{provision_total} ? 'yes' : 'no'), 'yes');
    ok_case('degrade: failure recorded',
        (exists $degraded->{errors}{'volumes:P1'} ? 'yes' : 'no'), 'yes');
}

print $fail ? "\n$fail FAILURE(S)\n" : "\nall api cases pass\n";
exit($fail ? 1 : 0);
