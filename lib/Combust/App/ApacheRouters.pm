package Combust::App::ApacheRouters;
use Moose::Role;
use Config::General ();
use Combust::Config ();
with 'Combust::ApacheConfig::Role';

sub BUILD {}

before 'BUILD' => sub {
    my $self   = shift;

    my $apache = $self->apache_config;

    if (%$apache) {

        my @virt;
        while (my ($port, $data) = each %{$apache->{VirtualHost}}) {
            push @virt, ref $data ? @{$data} : $data;
        }

        for my $virt (@virt) {
            
            # warn Dumper(\$virt);

            my @vars;
            if ($virt->{PerlSetVar}) {
                @vars = (
                ref $virt->{PerlSetVar}
                  ? @{$virt->{PerlSetVar}}
                  : $virt->{PerlSetVar});
            }

            my $domain = $virt->{ServerName};
            my ($site_name) = map { s/^site\s+//; $_ } grep {m/^site\s+/} @vars;
            $site_name ||= 'combust-default' if $domain eq 'combust-default';

            my $site = $self->sites->{$site_name}
              ||= Combust::Site->new(name => $site_name, domain => $domain);
            my $router = $site->router;

            $site->domain($domain) unless $site->domain;
            $site->domain_aliases(
                [   grep {$_} ref $virt->{ServerAlias}
                    ? @{$virt->{ServerAlias}}
                    : $virt->{ServerAlias}
                ]
            );

            $self->_connect_locations($router, $virt->{Location});

        }
    }

};


sub _connect_locations {
    my ($self, $router, $locations) = @_;

    my @locations = sort { length $b <=> length $a } keys %$locations;

    for my $location (@locations) {
        my $loc_data = $locations->{$location};

        Data::Dump::pp("loc_data for $location", $loc_data);

        next if $loc_data->{SetHandler} eq 'server-status';
        next if $loc_data->{SetHandler} eq 'cgi-script';

        if ($loc_data->{SetHandler} =~ m/^default(-handler)?$/) {
            $loc_data->{SetHandler}  = 'perl-script';
            # TODO: make a separate handler that always just serves the files as-is
            $loc_data->{PerlHandler} = 'Combust::Control::Basic';
        }

        if ($loc_data->{SetHandler} eq 'perl-script') {

            my $handler = $loc_data->{PerlHandler} || $loc_data->{PerlResponseHandler};
            $handler =~ s/^\+//;
            die "no PerlHandler for $location" unless $handler;
            $handler =~ s/->super//;

            $location .=
              $location =~ m{/$}
              ? ".*"
              : "(?:/.*)?";

            {
                my $module = $handler;
                $module =~ s{::}{/}g;
                require "$module.pm"
                  or die "Could not load $handler: $!";
            }

            $router->connect(
                qr{^($location)} => {
                    controller => $handler,
                    action     => 'render',
                }
            );

            next;
        }
        die "Unsupported handler $loc_data->{SetHandler}";
    }
}


1;
