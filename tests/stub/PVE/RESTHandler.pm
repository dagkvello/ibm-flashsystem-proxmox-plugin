package PVE::RESTHandler;
# Test stub: records register_method calls so tests can assert on the
# registered API surface without a PVE node.
use strict;
use warnings;

our %methods;

sub register_method {
    my ($class, $m) = @_;
    push @{ $methods{$class} }, $m;
    return 1;
}

sub registered {
    my ($class) = @_;
    return $methods{$class} // [];
}

1;
