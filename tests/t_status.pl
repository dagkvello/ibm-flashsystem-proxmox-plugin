#!/usr/bin/env perl
#
# Unit tests for _pool_usage — the capacity numbers status() hands to PVE
# (see files/UPSTREAM.md; the physical-capacity preference is a local
# deviation).
#
# Data-reduction pools on FCM drives report `capacity` in effective terms;
# the physical_* fields are what can actually still be written. Getting the
# preference wrong in one direction shows operators 44 TiB of free space that
# is physically 4 TiB; wrong in the other direction breaks standard pools
# that have no physical_* fields at all.
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
# Dual-home: ../files/ in a vendored layout, ../ in the standalone repo.
my ($MOD) = grep { -f } ("$BIN/../files/FlashSystemPlugin.pm",
                         "$BIN/../FlashSystemPlugin.pm");
require $MOD;
my $U = \&PVE::Storage::Custom::FlashSystemPlugin::_pool_usage;

# Real lsmdiskgrp -bytes output from Pool0_Gold, 2026-08-12: a data-reduction
# pool whose effective capacity (59.2 TiB) is 4.6x its physical (12.75 TiB).
my $drp = {
    capacity                => '65120294141952',
    free_capacity           => '48911087566848',
    used_capacity           => '15124972175360',
    physical_capacity       => '14020451500032',
    physical_free_capacity  => '4550058049536',
};

# A standard pool: no physical_* fields (older firmware / non-DRP).
my $std = {
    capacity      => '2199023255552',
    free_capacity => '1099511627776',
    used_capacity => '1099511627776',
};

# Degenerate: fields present but zero (defensive — must fall back).
my $zero = { %$drp, physical_capacity => 0, physical_free_capacity => 0 };

# status() with a pre-seeded per-cycle cache: no REST happens, so the
# cache-hit path (tier and k8s storages sharing one pool) and the
# cached-failure path (down array probed once per cycle, every storage on it
# reporting inactive) are both testable offline.
my $scfg = { fsaddress => '192.0.2.55', fspool => 'Pool0_Gold' };
my $ckey = "flashsystem/192.0.2.55/Pool0_Gold";
my @hit  = PVE::Storage::Custom::FlashSystemPlugin->status('Gold', $scfg, { $ckey => $drp });
my @down = PVE::Storage::Custom::FlashSystemPlugin->status('Gold', $scfg, { $ckey => 0 });

my @t = (
  ['cache hit  = physical',     $hit[0],  14020451500032],
  ['cache hit  active',         $hit[3],  1],
  ['cache down = inactive',     $down[3], 0],
  ['cache down zero capacity',  $down[0], 0],
  ['drp total = physical',      ($U->($drp))[0], 14020451500032],
  ['drp free  = physical free', ($U->($drp))[1],  4550058049536],
  ['drp used  = total - free',  ($U->($drp))[2],  9470393450496],
  ['drp active',                ($U->($drp))[3],  1],
  ['std total = capacity',      ($U->($std))[0],  2199023255552],
  ['std free  = free_capacity', ($U->($std))[1],  1099511627776],
  ['std used  = used_capacity', ($U->($std))[2],  1099511627776],
  ['zero physical falls back',  ($U->($zero))[0], 65120294141952],
);

my $fail = 0;
for my $c (@t) {
    my ($name, $got, $want) = @$c;
    my $ok = (defined $got && defined $want && $got == $want);
    printf "%-28s %-16s %s\n", $name, ($got // '(undef)'), $ok ? 'ok' : "FAIL (want $want)";
    $fail++ if !$ok;
}
die "$fail status case(s) failed\n" if $fail;
print "all " . scalar(@t) . " status cases pass\n";
