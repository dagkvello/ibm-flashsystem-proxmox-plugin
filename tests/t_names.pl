#!/usr/bin/env perl
#
# Unit tests for the volname grammar and the 63-char array-name gate
# (see files/UPSTREAM.md — both are local deviations).
#
# The grammar decides three things at once: what parse_volname will activate,
# what alloc_image will create, and what list_images will report as ours.
# Too strict and real consumers break (Kubernetes CSI pvc-<uuid> names,
# PVE's own cloudinit and fleece volumes — the original enumeration rejected
# all three). Too loose and an array snapshot object ("<volname>.<snap>")
# could round-trip through list_images as a phantom volume.
#
# The length gate exists because Storage Virtualize caps object names at 63
# and mkvdisk past the cap fails with an opaque CMMVC error. The boundary
# case is real: fsprefix 'pmcl01_Archive' (15 with separator) + the CSI
# name shape vm-9999-pvc-<36-char-uuid> (48) = exactly 63.
#
# Run:  run.sh in this directory

use strict; use warnings;
use FindBin;
use lib "$FindBin::Bin/stub";
# Dual-home: ../files/ in a vendored layout, ../ in the standalone repo.
my ($MOD) = grep { -f } ("$FindBin::Bin/../files/FlashSystemPlugin.pm",
                         "$FindBin::Bin/../FlashSystemPlugin.pm");
require $MOD;
my $P = 'PVE::Storage::Custom::FlashSystemPlugin';
my $A = \&PVE::Storage::Custom::FlashSystemPlugin::_arrayname;

my $uuid = '752b7aad-ac2f-43fe-b0aa-1c89bf01bc88';    # 36 chars, from the real CSI failure

my $fail = 0;
sub ok_case {
    my ($name, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && $got eq $want);
    printf "%-34s %-30s %s\n", $name, (defined $got ? $got : '(undef)'),
        $ok ? 'ok' : 'FAIL want=' . (defined $want ? $want : '(undef)');
    $fail++ if !$ok;
}

# ---- parse_volname: accepted shapes return (vtype, name, vmid) -------------
for my $c (
    ['disk',      'vm-101-disk-0',        101],
    ['state',     'vm-101-state-test',    101],
    ['state dot', 'vm-101-state-a.b',     101],    # PVE names these; dots allowed here only
    ['csi pvc',   "vm-9999-pvc-$uuid",   9999],
    ['cloudinit', 'vm-101-cloudinit',     101],
    ['fleece',    'vm-101-fleece-0',      101],
) {
    my ($label, $vol, $vmid) = @$c;
    my ($vt, $n, $id) = eval { $P->parse_volname($vol) };
    ok_case("parse $label", $@ ? '(died)' : "$vt/$id", "images/$vmid");
    ok_case("parse $label name", $@ ? '(died)' : $n, $vol);
}

# ---- parse_volname: rejected shapes ----------------------------------------
for my $c (
    ['empty suffix',   'vm-101-'],
    ['leading dot',    'vm-101-.bad'],
    ['snapshot shape', 'vm-101-disk-0.test'],    # array snapshot object — never a volume
    ['base image',     'base-101-disk-0'],       # no COW/template support
    ['non-numeric id', 'vm-abc-disk-0'],
    ['space',          'vm-101-disk 0'],
    # The three verified regex attacks (see UPSTREAM.md 1c): names arrive
    # from decode_json, which can hand back UTF-8-flagged strings.
    ['trailing newline',  "vm-101-disk-0\n"],           # $ would accept; \z must not
    ['fullwidth digits',  "vm-\x{FF11}\x{FF10}\x{FF11}-disk-0"],    # Unicode \d without /a
    ['unicode word chars', "vm-101-d\x{E4}t\x{E4}"],    # Unicode \w without /a
) {
    my ($label, $vol) = @$c;
    my $got = eval { $P->parse_volname($vol); 'parsed' } // 'rejected';
    ok_case("reject $label", $got, 'rejected');
}

# ---- alloc_image gates: both die before any REST call ----------------------
my $scfg = { fsprefix => 'pmcl01_Archive', fspool => 'Pool3_Archive' };

# The documented boundary: Archive's 15-char prefix + 48-char CSI name = 63.
ok_case('boundary arithmetic',
    length($A->($scfg, "vm-9999-pvc-$uuid")), 63);

# One past the boundary must fail with the actionable message, not CMMVC.
my $long = 'vm-9999-pvc-' . ('a' x 37);    # arrayname = 64
eval { $P->alloc_image('Archive', $scfg, 9999, 'raw', $long, 1024) };
ok_case('alloc >63 dies', ($@ && $@ =~ /max 63/) ? 'max-63 error' : "(!? $@)", 'max-63 error');
ok_case('alloc >63 names the fix', ($@ && $@ =~ /shorter fsprefix/) ? 'yes' : 'no', 'yes');

# Illegal shape still dies first, with the original error.
eval { $P->alloc_image('Archive', $scfg, 9999, 'raw', 'vm-9999-disk 0', 1024) };
ok_case('alloc illegal name dies', ($@ && $@ =~ /illegal name/) ? 'illegal-name error' : "(!? $@)",
    'illegal-name error');

# VMID in the name must match the owner PVE passed.
eval { $P->alloc_image('Archive', $scfg, 101, 'raw', "vm-9999-pvc-$uuid", 1024) };
ok_case('alloc vmid mismatch dies', ($@ && $@ =~ /illegal name/) ? 'illegal-name error' : "(!? $@)",
    'illegal-name error');

# Non-raw formats are still refused.
eval { $P->alloc_image('Archive', $scfg, 101, 'qcow2', 'vm-101-disk-0', 1024) };
ok_case('alloc qcow2 dies', ($@ && $@ =~ /only raw/) ? 'raw-only error' : "(!? $@)", 'raw-only error');

# ---- _mkvdisk_params: the thin-provisioning shape (fsthin) -----------------
# Bare mkvdisk = fully allocated (confirmed live 2026-08-25). fsthin adds
# rsize/autoexpand/warning; nothing else about the call may change.
use JSON ();
my $MK = \&PVE::Storage::Custom::FlashSystemPlugin::_mkvdisk_params;
my $thick = $MK->({ fspool => 'P' }, 'x-vm-1-disk-0', 1048576);
ok_case('thick: no rsize',        (exists $thick->{rsize} ? 'rsize' : 'none'), 'none');
ok_case('thick: no autoexpand',   (exists $thick->{autoexpand} ? 'yes' : 'none'), 'none');
ok_case('thick: no warning',      (exists $thick->{warning} ? 'yes' : 'none'), 'none');
ok_case('thick: size in bytes',   $thick->{size}, 1048576);
ok_case('thick: iogrp default',   $thick->{iogrp}, 'io_grp0');
my $thin = $MK->({ fspool => 'P', fsthin => 1, fsiogrp => 'io_grp1' }, 'x-vm-1-disk-0', 1048576);
ok_case('thin: rsize 2%',         $thin->{rsize}, '2%');
ok_case('thin: warning 80%',      $thin->{warning}, '80%');
# Must be a JSON boolean, not a plain 1: the array's valueless CLI flags are
# encoded as JSON true (the -bytes precedent) — "autoexpand":1 is a different
# request body than "autoexpand":true.
ok_case('thin: autoexpand JSON bool',
    (JSON::is_bool($thin->{autoexpand}) && $thin->{autoexpand}) ? 'true' : 'not-a-json-bool',
    'true');
ok_case('thin: size unchanged',   $thin->{size}, 1048576);
ok_case('thin: pool unchanged',   $thin->{mdiskgrp}, 'P');
ok_case('thin: iogrp override',   $thin->{iogrp}, 'io_grp1');
ok_case('thin: name unchanged',   $thin->{name}, 'x-vm-1-disk-0');

print $fail ? "\n$fail FAILURE(S)\n" : "\nall cases pass\n";
exit($fail ? 1 : 0);
