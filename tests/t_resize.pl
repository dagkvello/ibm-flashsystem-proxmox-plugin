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
# PVE runs its daemons under `perl -T`, so this suite does too. A plugin that
# passes here and then dies on the array with "Insecure dependency in open"
# is exactly what happened on 2026-08-31: every SCSI rescan and every path
# delete this plugin issued had been failing, unchecked, since the first
# release - while the same writes from a shell always worked.
#
# Taint mode rejects tainted @INC entries and a tainted require path, and
# FindBin derives both from $0. Untaint them HERE, in the harness, so the
# module under test still faces taint mode with ITS inputs (readlink, glob)
# tainted - which is the condition that actually matters.
# `our`, not `my`: a runtime `my` declaration re-initialises the variable to
# undef when execution reaches it, discarding what BEGIN put there.
our $BIN;
BEGIN { ($BIN) = $FindBin::Bin =~ m{\A(.*)\z}s; }
use lib "$BIN/stub";

my ($PLUGIN) = grep { -f } ("$BIN/../files/FlashSystemPlugin.pm",
                            "$BIN/../FlashSystemPlugin.pm");
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
# Untaint the fixture root, because in production $SYSFS_BLOCK is a LITERAL
# and therefore untainted, while the device names under it come from glob()
# and are tainted. tempdir() derives from $ENV{TMPDIR}, so leaving it tainted
# would taint the whole path and the test would pass or fail for a reason
# production never sees.
my $tmp = tempdir(CLEANUP => 1);
($tmp) = $tmp =~ m{\A(.*)\z}s;

sub settle {
    my (%a) = @_;
    my $wwid = $a{wwid} // 'testwwid';
    open(my $fh, '>', "$tmp/$wwid") or die "fixture: $!"; close $fh;
    my @seq = @{ $a{sizes} };
    my $rescans = 0;
    no warnings 'redefine', 'once';
    local $PVE::Storage::Custom::FlashSystemPlugin::MAPPER_DIR = $tmp;
    local $PVE::Storage::Custom::FlashSystemPlugin::RESIZE_SETTLE_TIMEOUT = $a{budget} // 0;
    # Drive the loop without spending wall-clock seconds; a unit suite that
    # sleeps for half a minute stops being run.
    local $PVE::Storage::Custom::FlashSystemPlugin::RESIZE_POLL_INTERVAL   = $a{poll} // 0;
    local $PVE::Storage::Custom::FlashSystemPlugin::RESIZE_RESCAN_INTERVAL = $a{nudge} // 30;
    local *PVE::Storage::Custom::FlashSystemPlugin::_dm_node = $a{dm_node} // sub { 'dm-test' };
    # Mirrors the real contract: (accepted, total, first_error).
    my $rescan_cb = $a{rescan} // sub { return (8, 8, undef) };
    local *PVE::Storage::Custom::FlashSystemPlugin::_rescan_paths =
        sub { $rescans++; return $rescan_cb->(@_) };
    local *PVE::Storage::Custom::FlashSystemPlugin::_path_sizes = sub { 'sdaa=21474836480' };
    my $on_resize = $a{on_resize} // sub { };
    local *PVE::Storage::Custom::FlashSystemPlugin::run_command = sub { $on_resize->(); 0 };
    local *PVE::Storage::Custom::FlashSystemPlugin::_dev_size = sub { @seq ? shift(@seq) : undef };
    my @pseq = @{ $a{paths} // $a{sizes} };
    local *PVE::Storage::Custom::FlashSystemPlugin::_paths_min_size =
        sub { @pseq ? shift(@pseq) : undef };
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
    my $r = settle(sizes  => [ 20 * $GB, 50 * $GB ],
                   paths  => [ 20 * $GB, 50 * $GB ],
                   want => 50 * $GB, budget => 30);
    ok_case('settle: catches up', $r->{ret}, 1);
    ok_case('settle: no error', ($r->{err} ? 'errored' : 'clean'), 'clean');
    # THE regression that cost two production rollouts: rescanning on every
    # pass re-triggers a SCSI rescan while one is still in flight, and then
    # none of them ever complete. 300s of that left the paths untouched; one
    # rescan and a short wait worked immediately. Rescan once, then wait.
    ok_case('settle: rescans ONCE, does not thrash', $r->{rescans}, 1);
}

# Only nudge again after a long quiet spell, never every pass.
{
    my $r = settle(sizes => [ (20 * $GB) x 40 ], paths => [ (20 * $GB) x 40 ],
                   want => 50 * $GB, budget => 3, nudge => 1);
    ok_case('settle: nudges sparingly, not every pass',
        ($r->{rescans} >= 2 && $r->{rescans} <= 5 ? 'yes' : "no:$r->{rescans}"), 'yes');
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
    # The config half is what a failed resize actually leaves behind, and
    # qm rescan is the only repair for it that cannot grow the array.
    ok_case('settle: points at qm rescan for the config',
        ($r->{err} =~ /qm rescan/a ? 'yes' : 'no'), 'yes');
    ok_case('settle: accounts for the rescans it issued',
        ($r->{err} =~ /rescans: \d+ pass/a ? 'yes' : 'no'), 'yes');
}

# A rescan this node never managed to ISSUE must not read, in the task log,
# like an array that is slow to publish. Live on 2026-08-31 those two were
# indistinguishable, and the whole day went into telling them apart.
{
    my $r = settle(sizes => [ (20 * $GB) x 6 ], want => 50 * $GB,
                   rescan => sub { return (0, 8, 'sdaa: open: Permission denied') });
    ok_case('settle: surfaces a rescan that did not land',
        ($r->{err} =~ /0 of 8 paths accepted/a ? 'yes' : 'no'), 'yes');
    ok_case('settle: names the rescan error',
        ($r->{err} =~ /Permission denied/a ? 'yes' : 'no'), 'yes');
}

# The device can be correct without any poll having seen it: multipathd
# resizes maps on its own once it notices the paths grew. The final verdict
# therefore has to re-read the device, not trust the snapshot taken before the
# loop - which is exactly what `$size = _dev_size($dm) if !defined $size` did,
# a no-op, because $size was always already defined.
{
    my $r = settle(sizes => [ 20 * $GB, 50 * $GB ], paths => [ undef ],
                   want => 50 * $GB, opt => { budget => 0 });
    ok_case('settle: final verdict re-reads the device', $r->{ret}, 1);
    ok_case('settle: and does not die on a device that is fine',
        ($r->{err} ? 'died' : 'clean'), 'clean');
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

# The map must not be resized while the paths are still behind: the map can
# only follow the paths, so an early resize is a no-op that muddies the
# diagnosis.
{
    my $resizes = 0;
    no warnings 'redefine';
    my $r = settle(sizes => [ 20 * $GB, 50 * $GB ], paths => [ 20 * $GB, 50 * $GB ],
                   want => 50 * $GB, budget => 30,
                   on_resize => sub { $resizes++ });
    ok_case('settle: map resized only once paths are ready', $resizes, 1);
}

# budget => 0 is what activate_volume passes: exactly one corrective pass, no
# sleeping. Every VM start and every migration goes through that path, so a
# device that will not catch up must cost ~nothing rather than 60 seconds.
{
    my $r = settle(sizes => [ 20 * $GB, 20 * $GB ], paths => [ 20 * $GB, 20 * $GB ],
                   want => 50 * $GB, opt => { best_effort => 1, budget => 0 });
    ok_case('attach: one corrective pass', $r->{rescans}, 1);
    ok_case('attach: never dies', ($r->{err} ? 'died' : 'survived'), 'survived');
}

# ...and when that single pass fixes it, the attach succeeds silently.
{
    my $r = settle(sizes => [ 20 * $GB, 50 * $GB ], paths => [ 50 * $GB, 50 * $GB ],
                   want => 50 * $GB, opt => { best_effort => 1, budget => 0 });
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
# Bounded, and long enough for the commit lag measured live: a +1G expand was
# still invisible to READ CAPACITY after 60s of continuous rescanning.
ok_case('settle timeout is bounded',
    ($PVE::Storage::Custom::FlashSystemPlugin::RESIZE_SETTLE_TIMEOUT >= 120
     && $PVE::Storage::Custom::FlashSystemPlugin::RESIZE_SETTLE_TIMEOUT <= 900) ? 'yes' : 'no', 'yes');

# ---- _rescan_paths itself, against a fixture /sys/block --------------------
# Everything above stubs this out, so until now the sub that does the actual
# work was the one part of the resize path with no test at all.
{
    use File::Path qw(make_path);
    my $sys = tempdir(CLEANUP => 1);
    make_path("$sys/dm-test/slaves/sdaa", "$sys/dm-test/slaves/sdbb",
              "$sys/sdaa/device");
    # sdaa can be rescanned; sdbb has no device/rescan at all, which is what a
    # path that has gone away underneath the map looks like.
    open(my $w, '>', "$sys/sdaa/device/rescan") or die $!; close $w;

    no warnings 'once';
    local $PVE::Storage::Custom::FlashSystemPlugin::SYSFS_BLOCK = $sys;
    my ($ok, $total, $err) =
        PVE::Storage::Custom::FlashSystemPlugin::_rescan_paths('dm-test');
    ok_case('rescan: counts the writes that landed', $ok, 1);
    ok_case('rescan: counts every path', $total, 2);
    ok_case('rescan: names the path that failed',
        (defined $err && $err =~ /\Asdbb:/a ? 'yes' : 'no:' . ($err // 'undef')), 'yes');

    # Opening the file is not the same as writing to it. The old version could
    # not tell the difference, and a silently-dropped write is the one failure
    # that looks exactly like a slow array.
    open(my $r, '<', "$sys/sdaa/device/rescan") or die $!;
    my $wrote = do { local $/; <$r> };
    close $r;
    ok_case('rescan: actually wrote the trigger', $wrote, "1\n");

    # THE 2026-08-31 root cause. PVE runs pvedaemon under `perl -T`; the device
    # names come from glob() and are tainted; a tainted path is legal in a read
    # open() and illegal in a write one. So every rescan this plugin ever
    # issued died with "Insecure dependency in open", in an eval, unchecked,
    # on all 8 paths - while _dev_size read those same paths without complaint
    # and the identical write from a shell always worked. The array was blamed
    # for a host-side bug for a full day. This whole file now runs under -T.
    ok_case('rescan: survives taint mode (-T)',
        (${^TAINT} ? ($ok == 1 ? 'wrote under -T' : 'BLOCKED BY TAINT') : 'not tainted'),
        'wrote under -T');

    my ($no_ok, $no_total, $no_err) =
        PVE::Storage::Custom::FlashSystemPlugin::_rescan_paths('dm-absent');
    ok_case('rescan: unknown dm reports zero paths', "$no_ok/$no_total", '0/0');
    ok_case('rescan: unknown dm explains itself',
        (defined $no_err ? 'yes' : 'no'), 'yes');
}

# ---- _flush_device deletes the SCSI paths, under taint ---------------------
# The detach path had the identical taint defect as the rescan and no test at
# all. Its consequence is worse than a failed resize: the comment on the sub
# explains that leaving stale sd nodes behind makes the array's next reuse of
# those LUN numbers reassemble the OLD wwid, so the new device never appears.
# That has been silently true on every detach this plugin has ever performed.
{
    my $sys = tempdir(CLEANUP => 1);
    ($sys) = $sys =~ m{\A(.*)\z}s;
    # The mapper dir lives INSIDE the fixture so the relative symlink below
    # resolves, exactly as /dev/mapper/<wwid> -> ../dm-N does on a real host.
    # _flush_device gates on -e $map, so a dangling link skips the whole body.
    my $mapdir = "$sys/mapper";
    make_path($mapdir, "$sys/dm-flush/slaves/sdxx", "$sys/sdxx/device");
    open(my $d, '>', "$sys/sdxx/device/delete") or die $!; close $d;
    # readlink() is what taints the dm name in production, so the fixture has
    # to be a real symlink rather than a plain file.
    symlink("../dm-flush", "$mapdir/wwidflush") or die "symlink: $!";

    no warnings 'redefine', 'once';
    local $PVE::Storage::Custom::FlashSystemPlugin::SYSFS_BLOCK = $sys;
    local $PVE::Storage::Custom::FlashSystemPlugin::MAPPER_DIR  = $mapdir;
    my @ran;
    local *PVE::Storage::Custom::FlashSystemPlugin::run_command =
        sub { push @ran, $_[0]; 0 };
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, $_[0] };

    my $got = PVE::Storage::Custom::FlashSystemPlugin::_flush_device('wwidflush');
    ok_case('flush: returns cleanly', $got, 1);
    ok_case('flush: flushed the map',
        ((grep { $_->[0] eq 'multipath' && $_->[1] eq '-f' } @ran) ? 'yes' : 'no'), 'yes');

    open(my $r, '<', "$sys/sdxx/device/delete") or die $!;
    my $wrote = do { local $/; <$r> };
    close $r;
    ok_case('flush: deleted the SCSI path under -T', $wrote, "1\n");
    ok_case('flush: silent when every path went away',
        (scalar(@warned) ? "warned: $warned[0]" : 'silent'), 'silent');
}

# ...and a path it could NOT delete has to be said out loud, not swallowed.
{
    my $sys = tempdir(CLEANUP => 1);
    ($sys) = $sys =~ m{\A(.*)\z}s;
    my $mapdir = "$sys/mapper";
    make_path($mapdir, "$sys/dm-stuck/slaves/sdyy");  # no $sys/sdyy/device/delete
    symlink("../dm-stuck", "$mapdir/wwidstuck") or die "symlink: $!";

    no warnings 'redefine', 'once';
    local $PVE::Storage::Custom::FlashSystemPlugin::SYSFS_BLOCK = $sys;
    local $PVE::Storage::Custom::FlashSystemPlugin::MAPPER_DIR  = $mapdir;
    local *PVE::Storage::Custom::FlashSystemPlugin::run_command = sub { 0 };
    my @warned;
    local $SIG{__WARN__} = sub { push @warned, $_[0] };

    PVE::Storage::Custom::FlashSystemPlugin::_flush_device('wwidstuck');
    ok_case('flush: warns about a path it could not delete',
        ((grep { /could not be deleted/ } @warned) ? 'yes' : 'no'), 'yes');
    ok_case('flush: explains why that matters',
        ((grep { /reassemble the OLD map/ } @warned) ? 'yes' : 'no'), 'yes');
}

print $fail ? "\n$fail FAILURE(S)\n" : "\nall resize cases pass\n";
exit($fail ? 1 : 0);
