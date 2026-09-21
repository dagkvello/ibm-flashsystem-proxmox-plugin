#!/usr/bin/env perl
#
# Unit tests for transport selection, NVMe device-id candidates, mkvolume
# params, and provisioning-policy detection. No array needed.

use strict; use warnings;
use FindBin;
use JSON ();
our $BIN;
BEGIN { ($BIN) = $FindBin::Bin =~ m{\A(.*)\z}s; }
use lib "$BIN/stub";
my ($MOD) = grep { -f } ("$BIN/../files/FlashSystemPlugin.pm",
                         "$BIN/../FlashSystemPlugin.pm");
require $MOD;
my $P = 'PVE::Storage::Custom::FlashSystemPlugin';

my $fail = 0;
sub ok_case {
    my ($name, $got, $want) = @_;
    my $ok = (!defined $got && !defined $want)
          || (defined $got && defined $want && "$got" eq "$want");
    printf "%-42s %-24s %s\n", $name, (defined $got ? $got : '(undef)'),
        $ok ? 'ok' : 'FAIL want=' . (defined $want ? $want : '(undef)');
    $fail++ if !$ok;
}

my $TR  = \&PVE::Storage::Custom::FlashSystemPlugin::_transport;
my $NV  = \&PVE::Storage::Custom::FlashSystemPlugin::_is_nvme;
my $NTT = \&PVE::Storage::Custom::FlashSystemPlugin::_nvme_trtype;
my $CAND = \&PVE::Storage::Custom::FlashSystemPlugin::_nvme_id_candidates;
my $UID = \&PVE::Storage::Custom::FlashSystemPlugin::_uid_hex;
my $POL = \&PVE::Storage::Custom::FlashSystemPlugin::_pool_has_policy;
my $CC  = \&PVE::Storage::Custom::FlashSystemPlugin::_create_cmd;
my $MKV = \&PVE::Storage::Custom::FlashSystemPlugin::_mkvolume_params;

# ---- transport --------------------------------------------------------------
ok_case('default transport scsi-fc', $TR->({}), 'scsi-fc');
ok_case('fc alias', $TR->({ fstransport => 'fc' }), 'scsi-fc');
ok_case('nvme-fc', $TR->({ fstransport => 'nvme-fc' }), 'nvme-fc');
ok_case('nvme/tcp alias', $TR->({ fstransport => 'nvme/tcp' }), 'nvme-tcp');
ok_case('nvme-rdma', $TR->({ fstransport => 'NVME-RDMA' }), 'nvme-rdma');
ok_case('is_nvme scsi', $NV->({}) ? 'yes' : 'no', 'no');
ok_case('is_nvme tcp', $NV->({ fstransport => 'nvme-tcp' }) ? 'yes' : 'no', 'yes');
ok_case('trtype tcp', $NTT->({ fstransport => 'nvme-tcp' }), 'tcp');
ok_case('trtype fc', $NTT->({ fstransport => 'nvme-fc' }), 'fc');
ok_case('trtype scsi none', (defined $NTT->({}) ? 'set' : 'none'), 'none');
eval { $TR->({ fstransport => 'iscsi' }) };
ok_case('unknown transport dies', ($@ ? 'died' : 'lived'), 'died');

# ---- NVMe by-id candidates from vdisk_UID ----------------------------------
my $uid = '880000000000000b0050760071c60044';
my @c = $CAND->($uid);
ok_case('eui candidate', (grep { $_ eq "/dev/disk/by-id/nvme-eui.$uid" } @c) ? 'yes' : 'no', 'yes');
ok_case('nguid candidate', (grep { $_ eq "/dev/disk/by-id/nvme-nguid.$uid" } @c) ? 'yes' : 'no', 'yes');
ok_case('uuid candidate hyphenated',
    (grep { $_ =~ /nvme-uuid\.88000000-0000-000b-0050-760071c60044/ } @c) ? 'yes' : 'no', 'yes');
ok_case('uid hex strips 0x and case',
    $UID->({ vdisk_UID => 'AABBCC' }), 'aabbcc');

# ---- mkvolume / policy ------------------------------------------------------
ok_case('no policy on empty hash', $POL->({}) ? 'yes' : 'no', 'no');
ok_case('policy by name',
    $POL->({ provisioning_policy_name => 'thin-std' }) ? 'yes' : 'no', 'yes');
ok_case('policy none is absent',
    $POL->({ provisioning_policy_name => 'none' }) ? 'yes' : 'no', 'no');
ok_case('create default mkvolume', $CC->({}), 'mkvolume');
ok_case('create mkvdisk override', $CC->({ fscreate => 'mkvdisk' }), 'mkvdisk');

my $vol = $MKV->({ fspool => 'P', fsthin => 1 }, 'pre-vm-1-disk-0', 1048576, 0);
ok_case('mkvolume pool field', $vol->{pool}, 'P');
ok_case('mkvolume no mdiskgrp', (exists $vol->{mdiskgrp} ? 'yes' : 'no'), 'no');
ok_case('mkvolume thin JSON bool',
    (JSON::is_bool($vol->{thin}) && $vol->{thin}) ? 'true' : 'not-bool', 'true');
ok_case('mkvolume unit b', $vol->{unit}, 'b');

my $pol = $MKV->({ fspool => 'P', fsthin => 1, fsvolumegroup => 'vg-pbr' },
    'pre-vm-1-disk-0', 1048576, 1);
ok_case('policy suppresses thin', (exists $pol->{thin} ? 'yes' : 'no'), 'no');
ok_case('volumegroup passed through', $pol->{volumegroup}, 'vg-pbr');

# ---- rename / snapname guards (die before REST) ----------------------------
eval { $P->volume_resize({ fsprefix => 'p' }, 's', 'vm-1-disk-0', 100, 0, 'snap1') };
ok_case('resize snapname dies', ($@ && $@ =~ /resizing a snapshot/) ? 'yes' : "(!? $@)", 'yes');

eval { $P->rename_volume({ fsprefix => 'p' }, 's', 'vm-1-disk-0', 2, 'vm-2-disk 0') };
ok_case('rename illegal name dies', ($@ && $@ =~ /illegal name/) ? 'yes' : "(!? $@)", 'yes');

ok_case('feature rename advertised',
    $P->volume_has_feature({}, 'rename', 's', 'vm-1-disk-0', undef, 0) ? 'yes' : 'no', 'yes');
ok_case('qemu snapshot method storage',
    $P->volume_qemu_snapshot_method('s', {}, 'vm-1-disk-0'), 'storage');

my $VA = \&PVE::Storage::Custom::FlashSystemPlugin::_valid_nvme_addr;
ok_case('tcp ipv4 ok', $VA->('tcp', '10.10.10.1') ? 'yes' : 'no', 'yes');
ok_case('fc wwpn ok', $VA->('fc', 'nn-0x200400a0b0c0d0e0:pn-0x210400a0b0c0d0e0') ? 'yes' : 'no', 'yes');
ok_case('fc garbage rejected', $VA->('fc', '10.10.10.1') ? 'yes' : 'no', 'no');
ok_case('shell metachar rejected', $VA->('tcp', '1.2.3.4;id') ? 'yes' : 'no', 'no');
ok_case('newline rejected', $VA->('tcp', "10.0.0.1\n") ? 'yes' : 'no', 'no');

print $fail ? "\n$fail FAILURE(S)\n" : "\nall nvme/alloc cases pass\n";
exit($fail ? 1 : 0);
