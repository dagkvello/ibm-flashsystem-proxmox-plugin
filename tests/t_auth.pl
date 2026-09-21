#!/usr/bin/env perl
#
# Unit tests for JWT refresh and 9.1 403-expiry handling (no array needed).

use strict; use warnings;
use FindBin;
use MIME::Base64 qw(encode_base64);
use JSON qw(encode_json);
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
          || (defined $got && defined $want && $got eq $want);
    printf "%-42s %-24s %s\n", $name, (defined $got ? $got : '(undef)'),
        $ok ? 'ok' : 'FAIL want=' . (defined $want ? $want : '(undef)');
    $fail++ if !$ok;
}

sub b64url {
    my ($s) = @_;
    my $b = encode_base64($s, '');
    $b =~ tr/+\//-_/;
    $b =~ s/=+$//;
    return $b;
}

sub jwt {
    my ($exp) = @_;
    return b64url('{"alg":"none"}') . '.' . b64url(encode_json({ exp => $exp })) . '.sig';
}

ok_case('api clamps to PLUGIN_APIVER_MAX',
    $P->api() <= PVE::Storage::Custom::FlashSystemPlugin::PLUGIN_APIVER_MAX() ? 'yes' : 'no',
    'yes');
ok_case('PLUGIN_APIVER_MAX is 15',
    PVE::Storage::Custom::FlashSystemPlugin::PLUGIN_APIVER_MAX(), 15);

my $EXP = \&PVE::Storage::Custom::FlashSystemPlugin::_jwt_expiry;
my $REF = \&PVE::Storage::Custom::FlashSystemPlugin::_jwt_needs_refresh;
my $KEY = \&PVE::Storage::Custom::FlashSystemPlugin::_tokkey;

ok_case('opaque token has no expiry',
    (defined $EXP->('not-a-jwt') ? 'exp' : 'none'), 'none');
ok_case('jwt exp parsed',
    $EXP->(jwt(1_700_000_000)), 1_700_000_000);

ok_case('missing cache needs refresh',
    $REF->(undef) ? 'yes' : 'no', 'yes');
ok_case('opaque cached token is kept',
    $REF->({ token => 'opaque', exp => undef }) ? 'yes' : 'no', 'no');
ok_case('jwt in the future is kept',
    $REF->({ token => 't', exp => time() + 3600 }) ? 'yes' : 'no', 'no');
ok_case('jwt past exp needs refresh',
    $REF->({ token => 't', exp => time() - 10 }) ? 'yes' : 'no', 'yes');
ok_case('jwt inside skew needs refresh',
    $REF->({
        token => 't',
        exp   => time() + int(PVE::Storage::Custom::FlashSystemPlugin::JWT_REFRESH_SKEW() / 2),
    }) ? 'yes' : 'no', 'yes');

ok_case('tokkey includes user',
    $KEY->({ fsaddress => 'a', fsuser => 'rest' }), 'a|rest');

print $fail ? "\n$fail FAILURE(S)\n" : "\nall auth cases pass\n";
exit($fail ? 1 : 0);
