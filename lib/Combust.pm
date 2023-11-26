package Combust;
use strict;
use Combust::Config;
use 5.30.0;

our $VERSION = '3.001';

my $config = Combust::Config->new;

sub config {
    $config;
}

1;

__END__

=pod

=head2 Author

Ask Bjørn Hansen <ask@develooper.com>

=head2 Copyright

Copyright 2003-2009 Ask Bjørn Hansen
