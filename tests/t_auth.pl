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
ok_case('PLUGIN_APIVER_MAX is 17',
    PVE::Storage::Custom::FlashSystemPlugin::PLUGIN_APIVER_MAX(), 17);

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

my $RT = \&PVE::Storage::Custom::FlashSystemPlugin::_is_retryable_transport;
my $RD = \&PVE::Storage::Custom::FlashSystemPlugin::_retry_delay;
ok_case('retry timeout', $RT->('read timed out') ? 'yes' : 'no', 'yes');
ok_case('retry conn refused', $RT->('Connection refused') ? 'yes' : 'no', 'yes');
ok_case('do not retry cert fail',
    $RT->('certificate verify failed') ? 'yes' : 'no', 'no');
ok_case('do not retry self-signed',
    $RT->('self signed certificate') ? 'yes' : 'no', 'no');
ok_case('do not retry auth die', $RT->('flashsystem: auth failed: 403') ? 'yes' : 'no', 'no');
ok_case('backoff 0 is 1s', $RD->(undef, 0), 1);
ok_case('backoff 2 is 4s', $RD->(undef, 2), 4);
ok_case('backoff never 8s', $RD->(undef, 3), 4);

{
    no warnings 'redefine';
    my $slept = 0;
    local *PVE::Storage::Custom::FlashSystemPlugin::_sleep = sub { $slept += $_[0] // 0 };
    my $n = 0;
    eval {
        PVE::Storage::Custom::FlashSystemPlugin::_request_with_retry(
            sub { $n++; die "Connection refused\n"; },
            max_attempts => 3,
        );
    };
    ok_case('transport retry count', $n, 3);
    ok_case('transport retry gives up', ($@ =~ /Connection refused/ ? 'yes' : "no:$@"), 'yes');
    ok_case('transport retry slept', ($slept >= 3 ? 'yes' : "no:$slept"), 'yes');

    $n = 0;
    eval {
        PVE::Storage::Custom::FlashSystemPlugin::_request_with_retry(
            sub { $n++; die "certificate verify failed\n"; },
            max_attempts => 3,
        );
    };
    ok_case('cert fail is not retried', ($@ =~ /certificate verify failed/ ? 'yes' : "no:$@"), 'yes');
    ok_case('cert fail attempts', $n, 1);
}

{
    package FakeRes;
    sub new { my ($c, $code) = @_; bless { code => $code }, $c }
    sub can { return 1 if $_[1] eq 'code' || $_[1] eq 'header'; return }
    sub code { $_[0]{code} }
    sub header { return '2' if $_[1] eq 'Retry-After'; return }
}
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::FlashSystemPlugin::_sleep = sub { };
    my $n = 0;
    my $got = PVE::Storage::Custom::FlashSystemPlugin::_request_with_retry(
        sub { $n++; return FakeRes->new($n < 3 ? 429 : 200); },
        max_attempts => 3,
    );
    ok_case('http 429 retried to 200', ($got && $got->code == 200 ? 'yes' : 'no'), 'yes');
    ok_case('http 429 attempts', $n, 3);

    $n = 0;
    $got = PVE::Storage::Custom::FlashSystemPlugin::_request_with_retry(
        sub { $n++; return FakeRes->new($n < 3 ? 429 : 200); },
        max_attempts => 3,
        idempotent => 0,
    );
    ok_case('mutation 429 still retried', ($got && $got->code == 200 ? 'yes' : 'no'), 'yes');
    ok_case('mutation 429 attempts', $n, 3);

    $n = 0;
    $got = PVE::Storage::Custom::FlashSystemPlugin::_request_with_retry(
        sub { $n++; return FakeRes->new(500); },
        max_attempts => 3,
        idempotent => 0,
    );
    ok_case('mutation 500 not retried', $n, 1);
    ok_case('mutation 500 returned', ($got && $got->code == 500 ? 'yes' : 'no'), 'yes');
}

{
    package FakeBody;
    sub new { my ($c, %h) = @_; bless \%h, $c }
    sub can { return 1 if $_[1] =~ /\A(?:code|header|decoded_content|status_line)\z/; return }
    sub code { $_[0]{code} }
    sub header { return $_[0]{headers}{ $_[1] } }
    sub decoded_content { $_[0]{body} // '' }
    sub status_line { $_[0]{status} // $_[0]{code} }
}
{
    no warnings 'redefine';
    local *PVE::Storage::Custom::FlashSystemPlugin::_sleep = sub { };
    my $n = 0;
    eval {
        PVE::Storage::Custom::FlashSystemPlugin::_request_with_retry(
            sub { $n++; die "Connection refused\n"; },
            max_attempts => 3,
            idempotent => 0,
        );
    };
    ok_case('mutation transport not retried', $n, 1);
    ok_case('mutation transport dies', ($@ =~ /Connection refused/ ? 'yes' : "no:$@"), 'yes');

    $n = 0;
    my $got = PVE::Storage::Custom::FlashSystemPlugin::_request_with_retry(
        sub {
            $n++;
            return FakeBody->new(code => 500, body => "certificate verify failed\n",
                status => '500 certificate verify failed');
        },
        max_attempts => 3,
    );
    ok_case('cert 500 is one attempt', $n, 1);
    ok_case('cert 500 returned', ($got && $got->code == 500 ? 'yes' : 'no'), 'yes');

    $n = 0;
    $got = PVE::Storage::Custom::FlashSystemPlugin::_request_with_retry(
        sub { $n++; return FakeBody->new(code => 500, body => "timeout\n", status => '500'); },
        max_attempts => 3,
    );
    ok_case('alarm timeout 500 is one attempt', $n, 1);

    $n = 0;
    $got = PVE::Storage::Custom::FlashSystemPlugin::_request_with_retry(
        sub {
            $n++;
            return FakeBody->new(code => 500, body => "read timed out\n") if $n < 2;
            return FakeBody->new(code => 200, body => 'ok');
        },
        max_attempts => 3,
    );
    ok_case('read timeout 500 still retried', ($got && $got->code == 200 ? 'yes' : 'no'), 'yes');
    ok_case('read timeout 500 attempts', $n, 2);
}

{
    my $REFH = \&PVE::Storage::Custom::FlashSystemPlugin::_snapshot_ref;
    ok_case('snapshot ref prefers uuid',
        $REFH->({ snapshot_id => '4', snapshot_uuid => 'abc-def' }), 'abc-def');
    ok_case('snapshot ref keeps numeric id',
        $REFH->({ snapshot_id => '4', snapshot_uuid => '9' }), '4');
    my $VG = \&PVE::Storage::Custom::FlashSystemPlugin::_volume_group_label;
    ok_case('volume group name',
        $VG->({ volume_group_name => 'vg1' }, {}), 'vg1');
    ok_case('volume group absent',
        $VG->({ volume_group_name => '' }, { fsvolumegroup => 'vg1' }), undef);
}

print $fail ? "\n$fail FAILURE(S)\n" : "\nall auth cases pass\n";
exit($fail ? 1 : 0);
