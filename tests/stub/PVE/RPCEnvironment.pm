package PVE::RPCEnvironment;
# Test stub: permissive environment for load-time tests only.
use strict;
use warnings;

sub get { return bless {}, __PACKAGE__; }
sub get_user { return 'root@pam'; }
sub check_any { return 1; }

1;
