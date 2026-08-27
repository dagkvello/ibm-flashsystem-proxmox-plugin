#!/usr/bin/env perl
#
# Unit tests for the fsprefix translation added to our vendored
# FlashSystemPlugin.pm (see files/UPSTREAM.md — this is a local deviation).
#
# The array-side object name carries a per-cluster prefix while the PVE volname
# stays canonical. Getting the inverse wrong in either direction is a data-loss
# bug: too permissive and a cluster lists (and can delete) another's disks, too
# strict and it cannot see its own.
#
# No FlashSystem needed — this exercises pure string translation. PVE's modules
# are stubbed because they only exist on a PVE node.
#
# Run:  run.sh in this directory

use strict; use warnings;
use FindBin;
use lib "$FindBin::Bin/stub";
# Dual-home: ../files/ in a vendored layout, ../ in the standalone repo.
my ($MOD) = grep { -f } ("$FindBin::Bin/../files/FlashSystemPlugin.pm",
                         "$FindBin::Bin/../FlashSystemPlugin.pm");
require $MOD;
my $A = \&PVE::Storage::Custom::FlashSystemPlugin::_arrayname;
my $V = \&PVE::Storage::Custom::FlashSystemPlugin::_volname_from_array;
my $SNAP = \&PVE::Storage::Custom::FlashSystemPlugin::_snap_name;
sub SNAPNAME { return $SNAP->(@_) }

my $p1 = { fsprefix => 'pvecl1' };
my $p2 = { fsprefix => 'pmcl02' };
my $no = {};

my @t = (
  # to-array
  ['to  pvecl1 disk',  $A->($p1,'vm-124-disk-0'),        'pvecl1-vm-124-disk-0'],
  ['to  pvecl1 state', $A->($p1,'vm-124-state-snap1'),   'pvecl1-vm-124-state-snap1'],
  ['to  no-prefix',    $A->($no,'vm-124-disk-0'),        'vm-124-disk-0'],
  ['to  empty prefix', $A->({fsprefix=>''},'vm-1-disk-0'), 'vm-1-disk-0'],
  # from-array, own
  ['fr  own',          $V->($p1,'pvecl1-vm-124-disk-0'), 'vm-124-disk-0'],
  # from-array, someone else's  -> must be undef (isolation)
  ['fr  other cluster', $V->($p1,'pmcl02-vm-124-disk-0'), undef],
  ['fr  unprefixed',    $V->($p1,'vm-124-disk-0'),        undef],
  ['fr  tier LUN',      $V->($p1,'Pool0_Gold_pvecl1_00'), undef],
  # from-array with no prefix configured: passthrough
  ['fr  no-prefix own', $V->($no,'vm-124-disk-0'),        'vm-124-disk-0'],
  # round-trip
  ['rt  pvecl1',       $V->($p1,$A->($p1,'vm-9-disk-3')), 'vm-9-disk-3'],
  ['rt  pmcl02',       $V->($p2,$A->($p2,'vm-9-disk-3')), 'vm-9-disk-3'],
  # cross round-trip must NOT resolve
  ['rt  cross',        $V->($p2,$A->($p1,'vm-9-disk-3')), undef],
  # prefix that is a prefix of another prefix (pmcl0 vs pvecl1)
  ['fr  near-miss',    $V->({fsprefix=>'pmcl0'},'pvecl1-vm-1-disk-0'), undef],

  # --- observed on a scratch cluster, snapshot "test" of
  # a running VM 102. These are the three object shapes the plugin actually
  # produces, confirmed against the array rather than assumed:
  #     vm-102-disk-0         the disk
  #     vm-102-state-test     the RAM state volume (named by PVE)
  #     vm-102-disk-0.test    the array snapshot object
  ['obs disk',         $A->($p1,'vm-102-disk-0'),       'pvecl1-vm-102-disk-0'],
  ['obs state',        $A->($p1,'vm-102-state-test'),   'pvecl1-vm-102-state-test'],
  ['obs snap',         SNAPNAME($A->($p1,'vm-102-disk-0'),'test'), 'pvecl1-vm-102-disk-0.test'],
  ['obs disk  back',   $V->($p1,'pvecl1-vm-102-disk-0'),     'vm-102-disk-0'],
  ['obs state back',   $V->($p1,'pvecl1-vm-102-state-test'), 'vm-102-state-test'],
);
my $fail = 0;
for my $c (@t) {
  my ($name,$got,$want) = @$c;
  my $ok = (!defined $got && !defined $want) || (defined $got && defined $want && $got eq $want);
  printf "%-22s %-28s %s\n", $name, (defined $got ? $got : '(undef)'), $ok ? 'ok' : "FAIL want=".(defined $want?$want:'(undef)');
  $fail++ unless $ok;
}
print $fail ? "\n$fail FAILURE(S)\n" : "\nall ".scalar(@t)." cases pass\n";
exit($fail ? 1 : 0);
