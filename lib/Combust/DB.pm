package Combust::DB;
use strict;
use DBI;
use Carp;
use Combust;

use Exporter;
use vars qw(@ISA @EXPORT_OK);
@EXPORT_OK = qw(db_open);
@ISA       = qw(Exporter);

my $config = Combust->config;

my %dbh = ();

sub read_db_connection_parameters {
    my $db_name = shift;
    my $db      = $config->database($db_name);
    $db and $db->{data_source} or croak "no data_source configured";
    my ($host) = ($db->{data_source} =~ m/host=([^;]+)/);
    return ($host, $db->{data_source}, $db->{user}, $db->{password});
}

sub db_open {
    my ($db, $attr) = @_;
    $db ||= 'combust';
    $attr = {} unless ref $attr;

    #carp "$$ Combust::DB::open_db called during server startup" if $Apache::Server::Starting;

    my $lock         = delete $attr->{lock};
    my $lock_timeout = delete $attr->{lock_timeout};
    my $lock_name    = delete $attr->{lock_name};

    # default to RaiseError=>1 but allow caller to override
    my $RaiseError = $attr->{RaiseError};
    $RaiseError = (defined $RaiseError) ? $RaiseError : 1;

    my $cache_key = $db . join "|", $$, map { $_, $attr->{$_} } sort keys %$attr;

    # TODO: cache attributes too, maybe subclass or use Apache::DBI somehow?
    my $dbh = $dbh{$cache_key};

    unless ($dbh and $dbh->ping()) {
        my ($host, @args) = read_db_connection_parameters($db);

        $dbh = DBI->connect(
            @args,
            {   ShowErrorStatement => 1,
                %$attr,
                RaiseError => 0,    # override RaiseError for connect
                AutoCommit => 1,    # make it explicit
            }
        );

        if ($dbh) {
            $dbh->{RaiseError} = $RaiseError;
            $dbh{$cache_key} = $dbh;
        }
        else {
            carp "Could not open $args[0] on $host: $DBI::errstr" if $RaiseError;

            # fall through if not RaiseError
        }
    }

    if ($lock) {
        $lock_timeout = 180 unless $lock_timeout;
        $lock_name    = $0  unless $lock_name;
        my ($lockok) =
          $dbh && $dbh->selectrow_array(qq[SELECT GET_LOCK("$lock_name",$lock_timeout)]);
        croak "Unable to get $lock_name lock for $0\n" unless $lockok;
    }

    # return handle; undef if connect failed and RaiseError is false
    return $dbh;
}

END {
    local ($!, $?);
    while (my ($db, $handle) = each %dbh) {
        $handle->disconnect() if $handle->{Active};
        delete $dbh{$db};
    }
}

1;
