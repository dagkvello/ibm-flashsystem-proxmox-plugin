package PVE::JSONSchema;
# Test stub: only what PVE::API2::FlashSystem imports.
use strict;
use warnings;
use Exporter 'import';

our @EXPORT_OK = qw(get_standard_option);

sub get_standard_option {
    my ($name, $extra) = @_;
    return { type => 'string', description => $name, %{ $extra // {} } };
}

1;
