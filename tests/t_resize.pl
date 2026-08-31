#!/usr/bin/env perl
#
# Unit tests for volume_resize and its host-side propagation.
#
# These exist because of a live failure on 2026-08-31: the array grew a Bronze
# volume from 20G to 50G, the host block device did not follow, and the only
# thing the operator saw was QEMU's "Cannot grow device files" - three layers
# from the cause, on a resize the array had already completed. The plugin knew
# the device was stale and discarded that knowledge.
#
# Run:  run.sh in this directory

use strict; use warnings;
use FindBin;
use lib "$FindBin::Bin/stub";

my ($PLUGIN) = grep { -f } ("$FindBin::Bin/../files/FlashSystemPlugin.pm",
                            "$FindBin::Bin/../FlashSystemPlugin.pm");
require $PLUGIN;
my $P = 'PVE::Storage::Custom::FlashSystemPlugin';

my $fail = 0;
sub ok_case {
    my ($name, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && $got eq $want);
    printf "%-42s %-24s %s\n", $name, (defined $got ? $got : '(undef)'),
        $ok ? 'ok' : 'FAIL want=' . (defined $want ? $want : '(undef)');
    $fail++ if !$ok;
}

my $GB = 1073741824;
my $scfg = { fsaddress => 'a', fspool => 'P', fsprefix => 'p' };

# Drive volume_resize with a stubbed array and a stubbed host, and report what
# each was asked to do.
sub run_resize {
    my ($current, $target) = @_;
    my (@array, @host);
    no warnings 'redefine';
    local *PVE::Storage::Custom::FlashSystemPlugin::_cmd = sub {
        my ($cfg, $command, $target_obj, $params) = @_;
        push @array, { cmd => $command, obj => $target_obj, params => $params };
        return { name => 'p-vm-1-disk-0', capacity => $current, vdisk_UID => 'ABC' }
            if $command eq 'lsvdisk';
        return undef;
    };
    local *PVE::Storage::Custom::FlashSystemPlugin::_resize_host_device = sub {
        push @host, [ @_ ];
        return 1;
    };
    my $err;
    eval { $P->volume_resize($scfg, 'store', 'vm-1-disk-0', $target, 0); 1 } or $err = $@;
    return { array => \@array, host => \@host, err => $err };
}

# ---- growing: array expanded by the delta, host told the ABSOLUTE size ------
{
    my $r = run_resize(20 * $GB, 50 * $GB);
    my ($expand) = grep { $_->{cmd} eq 'expandvdisksize' } @{ $r->{array} };
    ok_case('grow: expandvdisksize issued', ($expand ? 'yes' : 'no'), 'yes');
    # The array takes a DELTA; the host check needs the absolute target. Mixing
    # these up silently under-grows the device by the original size.
    ok_case('grow: array gets the delta', $expand->{params}{size}, 30 * $GB);
    ok_case('grow: delta is in bytes', $expand->{params}{unit}, 'b');
    ok_case('grow: prefix applied to object', $expand->{obj}, 'p-vm-1-disk-0');
    ok_case('grow: host propagation called', scalar(@{ $r->{host} }), 1);
    ok_case('grow: host gets the absolute size', $r->{host}[0][1], 50 * $GB);
    ok_case('grow: no error', ($r->{err} ? 'errored' : 'clean'), 'clean');
}

# ---- the retry case: array already at target, host still stale --------------
# This is the regression that made the live failure un-retryable from the GUI.
# The old code returned early on a zero delta, so the one path an operator
# would naturally take - "just try the resize again" - skipped host
# propagation entirely, which was the half that had actually failed.
{
    my $r = run_resize(50 * $GB, 50 * $GB);
    ok_case('retry: array left alone',
        (grep { $_->{cmd} eq 'expandvdisksize' } @{ $r->{array} }) ? 'expanded' : 'untouched',
        'untouched');
    ok_case('retry: host propagation STILL called', scalar(@{ $r->{host} }), 1);
    ok_case('retry: host gets the absolute size', $r->{host}[0][1], 50 * $GB);
    ok_case('retry: succeeds', ($r->{err} ? 'errored' : 'clean'), 'clean');
}

# ---- shrinking stays refused, before any array call ------------------------
{
    my $r = run_resize(50 * $GB, 20 * $GB);
    ok_case('shrink: refused', ($r->{err} && $r->{err} =~ /shrinking is not supported/ ? 'yes' : 'no'), 'yes');
    ok_case('shrink: no expand attempted',
        (grep { $_->{cmd} eq 'expandvdisksize' } @{ $r->{array} }) ? 'attempted' : 'none', 'none');
    ok_case('shrink: host untouched', scalar(@{ $r->{host} }), 0);
}

# ---- the settle loop itself -------------------------------------------------
# The previous version of these tests called _resize_host_device as a METHOD,
# so $wwid received the class name, /dev/mapper/<class name> did not exist, and
# the early return fired before any of the logic ran. It passed while testing
# nothing - a parameter swap in the sub survived it. $MAPPER_DIR exists so the
# loop can be driven against a fixture instead.
use File::Temp qw(tempdir);
my $tmp = tempdir(CLEANUP => 1);

sub settle {
    my (%a) = @_;
    my $wwid = $a{wwid} // 'testwwid';
    open(my $fh, '>', "$tmp/$wwid") or die "fixture: $!"; close $fh;
    my @seq = @{ $a{sizes} };
    my $rescans = 0;
    no warnings 'redefine', 'once';
    local $PVE::Storage::Custom::FlashSystemPlugin::MAPPER_DIR = $tmp;
    local $PVE::Storage::Custom::FlashSystemPlugin::RESIZE_SETTLE_TIMEOUT = $a{budget} // 0;
    local *PVE::Storage::Custom::FlashSystemPlugin::_dm_node = $a{dm_node} // sub { 'dm-test' };
    local *PVE::Storage::Custom::FlashSystemPlugin::_rescan_paths = sub { $rescans++ };
    local *PVE::Storage::Custom::FlashSystemPlugin::_path_sizes = sub { 'sdaa=21474836480' };
    local *PVE::Storage::Custom::FlashSystemPlugin::run_command = sub { 0 };
    local *PVE::Storage::Custom::FlashSystemPlugin::_dev_size = sub { @seq ? shift(@seq) : undef };
    my $got = eval {
        PVE::Storage::Custom::FlashSystemPlugin::_resize_host_device(
            $wwid, $a{want}, %{ $a{opt} // {} });
    };
    return { ret => $got, err => $@, rescans => $rescans };
}

# Already the right size: return immediately, touching nothing. This is the
# path every activate_volume takes, so it must not rescan or call multipathd.
{
    my $r = settle(sizes => [ 50 * $GB ], want => 50 * $GB);
    ok_case('settle: already correct returns 1', $r->{ret}, 1);
    ok_case('settle: already correct does no work', $r->{rescans}, 0);
}

# Behind, then catches up on a later poll - the live 2026-08-31 shape.
{
    my $r = settle(sizes => [ 20 * $GB, 20 * $GB, 50 * $GB ], want => 50 * $GB, budget => 30);
    ok_case('settle: catches up', $r->{ret}, 1);
    ok_case('settle: polled more than once', ($r->{rescans} >= 2 ? 'yes' : "no:$r->{rescans}"), 'yes');
    ok_case('settle: no error', ($r->{err} ? 'errored' : 'clean'), 'clean');
}

# Never catches up: must DIE, not return success onto a stale device. Returning
# success here is precisely what produced "Cannot grow device files".
{
    my $r = settle(sizes => [ (20 * $GB) x 6 ], want => 50 * $GB);
    ok_case('settle: stale device dies', ($r->{err} ? 'died' : 'returned ' . ($r->{ret} // 'undef')), 'died');
    ok_case('settle: names both sizes',
        ($r->{err} =~ /53687091200/a && $r->{err} =~ /21474836480/a ? 'yes' : 'no'), 'yes');
    ok_case('settle: reports the paths', ($r->{err} =~ /sdaa=/a ? 'yes' : 'no'), 'yes');
    # The array is already grown and PVE sizes from the array, so re-running
    # the resize would expand it AGAIN, permanently. The message must say so.
    ok_case('settle: warns against re-running the resize',
        ($r->{err} =~ /DO NOT re-run the resize/a ? 'yes' : 'no'), 'yes');
    ok_case('settle: gives the manual rescan',
        ($r->{err} =~ /multipathd resize map/a ? 'yes' : 'no'), 'yes');
}

# best_effort warns instead of dying - activate_volume must never block a VM
# start over a capacity mismatch.
{
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, $_[0] };
    my $r = settle(sizes => [ (20 * $GB) x 4 ], want => 50 * $GB, opt => { best_effort => 1 });
    ok_case('settle: best effort does not die', ($r->{err} ? 'died' : 'survived'), 'survived');
    ok_case('settle: best effort returns false', ($r->{ret} ? 'true' : 'false'), 'false');
    ok_case('settle: best effort still warns', (grep { /did not catch up/ } @warned) ? 'yes' : 'no', 'yes');
}

# budget => 0 is what activate_volume passes: exactly one corrective pass, no
# sleeping. Every VM start and every migration goes through that path, so a
# device that will not catch up must cost ~nothing rather than 60 seconds.
{
    my $r = settle(sizes => [ 20 * $GB, 20 * $GB ], want => 50 * $GB,
                   opt => { best_effort => 1, budget => 0 });
    ok_case('attach: one corrective pass', $r->{rescans}, 1);
    ok_case('attach: never dies', ($r->{err} ? 'died' : 'survived'), 'survived');
}

# ...and when that single pass fixes it, the attach succeeds silently.
{
    my $r = settle(sizes => [ 20 * $GB, 50 * $GB ], want => 50 * $GB,
                   opt => { best_effort => 1, budget => 0 });
    ok_case('attach: single pass can succeed', $r->{ret}, 1);
    ok_case('attach: succeeded on one rescan', $r->{rescans}, 1);
}

# An unnameable dm device is reported at once. Spending the whole budget to say
# "unreadable" would point the operator at the FC paths, which are fine.
{
    my $r = settle(sizes => [ 20 * $GB ], want => 50 * $GB, dm_node => sub { undef });
    ok_case('settle: unresolvable dm dies', ($r->{err} ? 'died' : 'returned'), 'died');
    ok_case('settle: says it cannot resolve',
        ($r->{err} =~ /cannot resolve a dm device/a ? 'yes' : 'no'), 'yes');
    ok_case('settle: did not burn the budget first', $r->{rescans}, 0);
}

# ---- a node that does not have the device attached is not an error ---------
# Every node except the one running the guest is in this state: deactivate_volume
# flushes the map, and the next activate_volume discovers the LUN fresh at its
# current size. Called as a FUNCTION - it is not a method.
{
    my $got = eval {
        PVE::Storage::Custom::FlashSystemPlugin::_resize_host_device(
            '3deadbeefdeadbeefdeadbeefdeadbeef', 50 * $GB);
    };
    ok_case('detached node: returns cleanly', ($@ ? "died: $@" : $got), 1);
}

# ---- the settle budget is a real, finite number ----------------------------
ok_case('settle timeout is bounded',
    ($PVE::Storage::Custom::FlashSystemPlugin::RESIZE_SETTLE_TIMEOUT > 0
     && $PVE::Storage::Custom::FlashSystemPlugin::RESIZE_SETTLE_TIMEOUT <= 300) ? 'yes' : 'no', 'yes');

print $fail ? "\n$fail FAILURE(S)\n" : "\nall resize cases pass\n";
exit($fail ? 1 : 0);
