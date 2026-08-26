package PVE::API2::FlashSystem;

# ---------------------------------------------------------------------------
# Read-only health & capacity API for `flashsystem` storages.
#
#   GET /nodes/{node}/flashsystem                      -> flashsystem storages
#   GET /nodes/{node}/flashsystem/{storage}            -> ['health']
#   GET /nodes/{node}/flashsystem/{storage}/health     -> one storage
#   GET /nodes/{node}/flashsystem/{storage}/overview   -> the whole array
#
# Proxmox has no API plugin registry, so this module is registered by
# appending a marker-wrapped block to PVE/API2/Nodes.pm — see
# install-flashsystem-api.sh, which also installs an APT hook to re-apply it
# after pve-manager upgrades. The GUI counterpart (a "FlashSystem" tab on the
# storage view) lives in flashsystem-gui.js.
#
# Every array read goes through the storage plugin's _cmd (429 retry, token
# cache) and each section is eval-guarded and time-bounded by a SHARED
# deadline: the whole collection fits inside ~25s because the
# pveproxy->pvedaemon proxy path caps requests at ~30s — independent
# per-section budgets would blow through it on a hung array and turn the
# designed partial-data response into a blunt proxy 5xx (VALIDATE the exact
# proxy timeout on a live node before raising the budget). A slow or
# unreachable array yields partial data with per-section errors, never a
# hung API worker. The health method is `protected` because resolving the
# REST credential reads root-only /etc/pve/priv/storage/<id>.pw.
#
# VALIDATE: the lseventlog filter (`fixed=no`) and the exact field names of
# lssystem/lsportfc/lseventlog concise views vary by firmware — confirm on a
# demo array before trusting the events/ports sections. Unknown fields are
# simply omitted (whitelist extraction), so mismatches degrade to empty
# sections rather than errors.
# ---------------------------------------------------------------------------

use strict;
use warnings;

use JSON ();
use PVE::JSONSchema qw(get_standard_option);
use PVE::RESTHandler;
use PVE::RPCEnvironment;
use PVE::Storage;

# The storage plugin provides _cmd/_one/_volname_from_array/_pool_usage. On a
# node it loads by module name; in the unit tests it has already been loaded
# from a flat file path, so only require it when it is not there yet.
BEGIN {
    unless (defined &PVE::Storage::Custom::FlashSystemPlugin::_cmd) {
        require PVE::Storage::Custom::FlashSystemPlugin;
    }
}

use base qw(PVE::RESTHandler);

# ---- pure view helpers (unit-tested in tests/t_api.pl) --------------------

# Copy only the listed keys that actually exist — firmware differences in
# concise-view fields degrade to omissions, never errors.
sub _whitelist {
    my ($h, @keys) = @_;
    return {} if ref($h) ne 'HASH';
    return { map { $_ => $h->{$_} } grep { defined $h->{$_} } @keys };
}

sub _system_view {
    my ($sys) = @_;
    return _whitelist($sys, qw(name code_level product_name topology));
}

sub _pool_view {
    my ($g) = @_;
    return {} if ref($g) ne 'HASH';
    my $v = _whitelist($g, qw(name status data_reduction
        capacity free_capacity used_capacity
        physical_capacity physical_free_capacity));
    # The same physical-over-effective preference status() uses: this is the
    # number people provision against (see UPSTREAM.md 1b).
    my ($total, $free, $used) = PVE::Storage::Custom::FlashSystemPlugin::_pool_usage($g);
    $v->{provision_total} = $total;
    $v->{provision_free}  = $free;
    $v->{provision_used}  = $used;
    $v->{provision_used_pct} = $total ? int($used * 100 / $total + 0.5) : 0;
    return $v;
}

sub _volumes_view {
    my ($vdisks, $scfg) = @_;
    $vdisks = [] if ref($vdisks) ne 'ARRAY';
    my ($ours, $bytes) = (0, 0);
    my $shape = qr/\Avm-\d+-$PVE::Storage::Custom::FlashSystemPlugin::VOLNAME_SUFFIX\z/a;
    for my $v (@$vdisks) {
        my $name = PVE::Storage::Custom::FlashSystemPlugin::_volname_from_array($scfg, $v->{name} // '');
        next if !defined $name;
        # The prefix alone is not enough: list_images ALSO requires the PVE
        # volume shape, and without that test a storage with no fsprefix —
        # where the translation is a pass-through — claims every object in
        # the pool. Observed live 2026-08-26: a prefix-less storage reported
        # 6 volumes / 5.6 TB while PVE managed 4 / 103 GB, the difference
        # being another consumer's volumes in a shared pool.
        next if $name !~ $shape;
        $ours++;
        $bytes += (($v->{capacity} // 0) + 0);
    }
    return {
        pool_total        => scalar(@$vdisks),
        ours              => $ours,
        ours_provisioned  => $bytes,
    };
}

# An unfixed event is not necessarily a problem. `fixed=no` also returns the
# array's informational chatter — SAS discovery, "Virtual Disk Copy Format
# Completed" — which on a working system runs to four figures: 1317 on the
# 8.7.0.3 demo array, of which exactly ONE was actionable. Alerts are the
# events carrying a real error code; informational events carry an empty one.
# Everything is counted, only alerts are listed, so a single 1867 pool-space
# warning cannot hide behind a thousand copy-format notices.
#
# Note this is ARRAY-WIDE: lseventlog is a system log, not a pool log, so
# every storage on the same array reports the same alerts.
#
# VALIDATE (payload optimisation, not correctness): Storage Virtualize also
# accepts a server-side `alert=yes` filter. Confirm the REST spelling on an
# array and the fetch shrinks from ~1300 rows to a handful; the client-side
# split below stays as the belt either way.
sub _events_view {
    my ($events, $max) = @_;
    $events = [] if ref($events) ne 'ARRAY';
    $max //= 10;
    my @alerts = grep {
        defined $_->{error_code} && $_->{error_code} =~ /\A\s*[1-9][0-9]*\s*\z/
    } @$events;
    my @sorted = sort { ($b->{sequence_number} // 0) <=> ($a->{sequence_number} // 0) } @alerts;
    my $last = $#sorted < $max - 1 ? $#sorted : $max - 1;
    my @recent = $last < 0 ? () : map {
        _whitelist($_, qw(sequence_number error_code description
            object_type object_name last_timestamp))
    } @sorted[0 .. $last];
    return {
        alerts        => scalar(@alerts),
        unfixed_total => scalar(@$events),
        recent        => \@recent,
    };
}

sub _ports_view {
    my ($ports, $max) = @_;
    $ports = [] if ref($ports) ne 'ARRAY';
    $max //= 16;
    my %by_status;
    $by_status{ lc($_->{status} // 'unknown') }++ for @$ports;
    my @rows = map {
        _whitelist($_, qw(id fc_io_port_id status port_speed attachment node_name))
    } @$ports[0 .. ($#$ports < $max - 1 ? $#$ports : $max - 1)];
    return {
        total     => scalar(@$ports),
        active    => ($by_status{active} // 0),
        by_status => \%by_status,
        ports     => \@rows,
    };
}

# ---- collection ------------------------------------------------------------

# The whole collection shares one deadline (see header): each section gets
# min(its cap, time remaining), and a section whose turn arrives after the
# deadline is skipped with an explicit error instead of silently stretching
# the request past the proxy timeout.
my $TOTAL_BUDGET = 25;    # seconds; pveproxy->pvedaemon caps at ~30 (VALIDATE)

sub _budget {
    my ($deadline, $cap) = @_;
    my $left = $deadline - time();
    return 0 if $left <= 0;
    return $left < $cap ? $left : $cap;
}

# One bounded REST call per section; failures become {error} entries so the
# panel renders partial data instead of nothing.
sub _section {
    my ($errors, $key, $deadline, $cap, $code) = @_;
    my $timeout = _budget($deadline, $cap);
    if (!$timeout) {
        $errors->{$key} = 'skipped: time budget exhausted';
        return undef;
    }
    my $res = eval {
        local $SIG{ALRM} = sub { die "timeout after ${timeout}s\n"; };
        alarm $timeout;
        my $r = $code->();
        alarm 0;
        $r;
    };
    alarm 0;
    if (my $err = $@) {
        chomp $err;
        $errors->{$key} = $err;
        return undef;
    }
    return $res;
}

sub _collect_health {
    my ($storeid, $scfg) = @_;

    my $deadline = time() + $TOTAL_BUDGET;
    my $errors = {};
    # fsprefix is reported so the panel can flag its absence: an unprefixed
    # storage cannot be isolated from other consumers of the same pool, and
    # the option is fixed after creation.
    my $health = {
        storage   => $storeid,
        pool_name => $scfg->{fspool},
        prefix    => $scfg->{fsprefix},
    };

    my $sys = _section($errors, 'system', $deadline, 8, sub {
        PVE::Storage::Custom::FlashSystemPlugin::_one(
            PVE::Storage::Custom::FlashSystemPlugin::_cmd($scfg, 'lssystem', undef, {}, storeid => $storeid));
    });
    $health->{system} = _system_view($sys) if $sys;

    my $pool = _section($errors, 'pool', $deadline, 8, sub {
        PVE::Storage::Custom::FlashSystemPlugin::_one(
            PVE::Storage::Custom::FlashSystemPlugin::_cmd($scfg, 'lsmdiskgrp', $scfg->{fspool},
                { bytes => JSON::true }, storeid => $storeid));
    });
    $health->{pool} = _pool_view($pool) if $pool;

    # For the list sections an empty REST body means "no rows" (the plugin's
    # _cmd returns undef for empty bodies): render an explicit zero, and only
    # omit the section when its call actually failed.
    my $vdisks = _section($errors, 'volumes', $deadline, 10, sub {
        PVE::Storage::Custom::FlashSystemPlugin::_cmd($scfg, 'lsvdisk', undef,
            { filtervalue => "mdisk_grp_name=$scfg->{fspool}", bytes => JSON::true },
            storeid => $storeid);
    });
    $health->{volumes} = _volumes_view($vdisks // [], $scfg) if !exists $errors->{volumes};

    my $events = _section($errors, 'events', $deadline, 8, sub {
        PVE::Storage::Custom::FlashSystemPlugin::_cmd($scfg, 'lseventlog', undef,
            { filtervalue => 'fixed=no' }, storeid => $storeid);
    });
    $health->{events} = _events_view($events // []) if !exists $errors->{events};

    my $ports = _section($errors, 'ports', $deadline, 8, sub {
        PVE::Storage::Custom::FlashSystemPlugin::_cmd($scfg, 'lsportfc', undef, {}, storeid => $storeid);
    });
    $health->{ports} = _ports_view($ports // []) if !exists $errors->{ports};

    $health->{errors} = $errors if %$errors;
    return $health;
}

# ---- API methods -----------------------------------------------------------

__PACKAGE__->register_method({
    name => 'index',
    path => '',
    method => 'GET',
    description => "List flashsystem storages defined on this node.",
    permissions => {
        description => "Only storages with Datastore.Audit or Datastore.Allocate are listed.",
        user => 'all',
    },
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node => get_standard_option('pve-node'),
        },
    },
    returns => {
        type => 'array',
        items => {
            type => 'object',
            properties => {
                storage => { type => 'string' },
                pool    => { type => 'string', optional => 1 },
                address => { type => 'string', optional => 1 },
            },
        },
        links => [ { rel => 'child', href => '{storage}' } ],
    },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $cfg = PVE::Storage::config();

        my $res = [];
        for my $storeid (sort keys %{ $cfg->{ids} // {} }) {
            my $scfg = $cfg->{ids}->{$storeid};
            next if ($scfg->{type} // '') ne 'flashsystem';
            next if !$rpcenv->check_any($authuser, "/storage/$storeid",
                [ 'Datastore.Audit', 'Datastore.Allocate' ], 1);
            push @$res, {
                storage => $storeid,
                pool    => $scfg->{fspool},
                address => $scfg->{fsaddress},
            };
        }
        return $res;
    },
});

__PACKAGE__->register_method({
    name => 'diridx',
    path => '{storage}',
    method => 'GET',
    description => "Index of available flashsystem storage reports.",
    permissions => {
        check => [ 'perm', '/storage/{storage}', [ 'Datastore.Audit', 'Datastore.Allocate' ], any => 1 ],
    },
    proxyto => 'node',
    parameters => {
        additionalProperties => 0,
        properties => {
            node    => get_standard_option('pve-node'),
            storage => get_standard_option('pve-storage-id'),
        },
    },
    returns => {
        type => 'array',
        items => { type => 'object', properties => { subdir => { type => 'string' } } },
        links => [ { rel => 'child', href => '{subdir}' } ],
    },
    code => sub {
        return [ { subdir => 'health' }, { subdir => 'overview' } ];
    },
});

__PACKAGE__->register_method({
    name => 'health',
    path => '{storage}/health',
    method => 'GET',
    description => "Array health and capacity overview for a flashsystem storage: "
        . "system identity, pool capacity (physical and effective), volume counts, "
        . "unfixed events and FC port state. Read-only; sections degrade "
        . "independently if the array is slow or unreachable.",
    # protected: resolving the REST credential reads root-only
    # /etc/pve/priv/storage/<id>.pw, which pveproxy's www-data cannot.
    protected => 1,
    proxyto => 'node',
    permissions => {
        check => [ 'perm', '/storage/{storage}', [ 'Datastore.Audit', 'Datastore.Allocate' ], any => 1 ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node    => get_standard_option('pve-node'),
            storage => get_standard_option('pve-storage-id'),
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $cfg = PVE::Storage::config();
        my $scfg = PVE::Storage::storage_config($cfg, $param->{storage});
        die "storage '$param->{storage}' is not a flashsystem storage\n"
            if ($scfg->{type} // '') ne 'flashsystem';
        return _collect_health($param->{storage}, $scfg);
    },
});


# ---- datacenter-wide overview ---------------------------------------------

# Short aliases: everything below talks to the array through the storage
# plugin's transport (429 retry, token cache).
sub _fscmd { return PVE::Storage::Custom::FlashSystemPlugin::_cmd(@_); }
sub _fsone { return PVE::Storage::Custom::FlashSystemPlugin::_one(@_); }

# Aggregate every flashsystem storage sharing one array. The array-wide facts
# (identity, ports, alerts) are fetched ONCE and each pool ONCE, however many
# storages use it — an 8-storage / 4-pool cluster costs 11 REST calls rather
# than the 40 a per-storage fan-out would. Same shared deadline as health(),
# so a slow array degrades to partial data instead of a proxy timeout.
#
# @peers is [[storeid, scfg], ...], already filtered by the caller for read
# permission: the overview must not leak storages the user cannot audit.
sub _collect_overview {
    my ($storeid, $scfg, $peers) = @_;

    my $deadline = time() + $TOTAL_BUDGET;
    my $errors = {};
    my $out = { array => $scfg->{fsaddress}, pools => [] };

    my $sys = _section($errors, 'system', $deadline, 8, sub {
        _fsone(_fscmd($scfg, 'lssystem', undef, {}, storeid => $storeid));
    });
    $out->{system} = _system_view($sys) if $sys;

    my $events = _section($errors, 'events', $deadline, 8, sub {
        _fscmd($scfg, 'lseventlog', undef, { filtervalue => 'fixed=no' }, storeid => $storeid);
    });
    $out->{events} = _events_view($events // []) if !exists $errors->{events};

    my $ports = _section($errors, 'ports', $deadline, 8, sub {
        _fscmd($scfg, 'lsportfc', undef, {}, storeid => $storeid);
    });
    $out->{ports} = _ports_view($ports // []) if !exists $errors->{ports};

    my %by_pool;
    for my $p (@$peers) {
        push @{ $by_pool{ $p->[1]->{fspool} // '' } }, $p;
    }

    for my $pool (sort keys %by_pool) {
        my $entry = { pool => $pool, storages => [] };

        my $g = _section($errors, "pool:$pool", $deadline, 6, sub {
            _fsone(_fscmd($scfg, 'lsmdiskgrp', $pool, { bytes => JSON::true }, storeid => $storeid));
        });
        $entry->{capacity} = _pool_view($g) if $g;

        my $vdisks = _section($errors, "volumes:$pool", $deadline, 8, sub {
            _fscmd($scfg, 'lsvdisk', undef,
                { filtervalue => "mdisk_grp_name=$pool", bytes => JSON::true },
                storeid => $storeid);
        });
        # A failed or skipped lsvdisk must NOT publish zeros: "0 volumes"
        # beside real capacity reads as an empty pool, not as missing data.
        # Same rule _collect_health applies to its own list sections.
        my $vol_ok = !exists $errors->{"volumes:$pool"};
        $entry->{pool_volumes} = scalar(@{ $vdisks // [] }) if $vol_ok;

        # One lsvdisk per pool, counted per storage by each storage's prefix.
        for my $p (@{ $by_pool{$pool} }) {
            my ($id, $s) = @$p;
            my $row = {
                storage   => $id,
                prefix    => $s->{fsprefix},
                thin      => ($s->{fsthin}      ? 1 : 0),
                snapshots => ($s->{fssnapshots} ? 1 : 0),
            };
            if ($vol_ok) {
                my $v = _volumes_view($vdisks // [], $s);
                $row->{volumes}     = $v->{ours};
                $row->{provisioned} = $v->{ours_provisioned};
            }
            push @{ $entry->{storages} }, $row;
        }
        push @{ $out->{pools} }, $entry;
    }

    $out->{errors} = $errors if %$errors;
    return $out;
}

__PACKAGE__->register_method({
    name => 'overview',
    path => '{storage}/overview',
    method => 'GET',
    description => "Array-wide overview for every flashsystem storage sharing "
        . "this storage's array: system identity, per-pool capacity, the storages "
        . "using each pool, FC port state and unfixed array alerts. Read-only. "
        . "Array facts and each pool are fetched once regardless of how many "
        . "storages share them.",
    protected => 1,
    proxyto => 'node',
    permissions => {
        check => [ 'perm', '/storage/{storage}', [ 'Datastore.Audit', 'Datastore.Allocate' ], any => 1 ],
    },
    parameters => {
        additionalProperties => 0,
        properties => {
            node    => get_standard_option('pve-node'),
            storage => get_standard_option('pve-storage-id'),
        },
    },
    returns => { type => 'object' },
    code => sub {
        my ($param) = @_;
        my $rpcenv = PVE::RPCEnvironment::get();
        my $authuser = $rpcenv->get_user();
        my $cfg = PVE::Storage::config();
        my $scfg = PVE::Storage::storage_config($cfg, $param->{storage});
        die "storage '$param->{storage}' is not a flashsystem storage\n"
            if ($scfg->{type} // '') ne 'flashsystem';

        my $addr = $scfg->{fsaddress} // '';
        my $peers = [];
        for my $id (sort keys %{ $cfg->{ids} // {} }) {
            my $s = $cfg->{ids}->{$id};
            next if ($s->{type} // '') ne 'flashsystem';
            next if ($s->{fsaddress} // '') ne $addr;
            next if !$rpcenv->check_any($authuser, "/storage/$id",
                [ 'Datastore.Audit', 'Datastore.Allocate' ], 1);
            push @$peers, [ $id, $s ];
        }
        return _collect_overview($param->{storage}, $scfg, $peers);
    },
});

1;
