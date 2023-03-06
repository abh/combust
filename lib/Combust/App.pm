package Combust::App;
use Moose;
use Plack;
use Plack::Builder;
use Plack::Request;
use Combust::Config;
use Combust::Site;
use Combust::Request::Plack;
use Combust::Constant qw(DECLINED);
use File::Path qw(mkpath);

my $config = Combust::Config->new;

use namespace::clean -except => 'meta';

has sites => (
    is      => 'rw',
    isa     => 'HashRef[Combust::Site]',
    default => sub { {} },
);

has domain_mapping => (
    is      => 'rw',
    isa     => 'HashRef',
    default => sub { {} },
);

has errorlog_stderr => (
    is      => 'ro',
    isa     => 'Bool',
    default => sub {1},
);

sub setup_mappings {
    my $self = shift;

    my %domains;
    for my $site (values %{$self->sites}) {
        for my $domain ($site->domain, $site->domain_alias_list) {
            if ($domains{$domain} && $domains{$domain} ne $site->name) {
                die "$domain specified twice (for $domains{$domain} and ", $site->name;
            }
            $domains{$domain} = $site->name;
        }
    }

    #warn "DOMAINS : ", Data::Dumper::Dumper(\%domains);

    $self->domain_mapping(\%domains);
}

sub map_domain_site {
    my ($self, $request) = @_;
    my $domain    = $request->base->host;
    my $site_name = $self->domain_mapping->{$domain} || $self->domain_mapping->{'*'};
    my $site      = $site_name && $self->sites->{$site_name};
    return $site ? $site : $self->sites->{'combust-default'};
}

sub setup_request {
    my ($self, $env) = @_;

    my $request = Combust::Request::Plack->new($env);
    my $site    = $self->map_domain_site($request);
    $request->site($site);

    return $request;
}

has 'rewriter' => (
    is       => 'rw',
    required => 0,
);

sub exec {

    my ($self, $env) = @_;
    my $request = $self->setup_request($env);

    #warn "ENV: ", pp(\$env);
    {
        if (my $rewriter = $self->rewriter) {
            $rewriter->request($request);
            my $r = $rewriter->run("rewrite");
            return $r unless $r->[0] == DECLINED;
        }
    }

    # todo: this is a little dubious, but ... practical?
    if ($request->path eq "/combust-healthz") {
        return [200, ['Content-Type' => 'text/plain'], ["Combust says ok\n"]];
    }

    my $match = $request->site->router->match($request->env);
    {
        my $module = $match->{controller};
        $module =~ s{::}{/}g;
        require "$module.pm";
    }

    my $controller = $match->{controller}->new(request => $request);
    my $r          = $controller->run($match->{action} || 'render');

    # use Data::Dump qw(pp);
    # warn "RETURN: ", pp($r);

    return $r;
}

sub init {
    my $self = shift;
    $self->setup_mappings;
}

sub _logfh {
    my $self = shift;
    $self->init;

    my $log_path = $config->log_path;

    my $logfh;

    if ($log_path eq "stdout") {
        return \*STDOUT;
    }

    unless (-e $log_path) {
        mkpath($log_path, 1) or die qq[Could not create "$log_path": $!];
    }

    if ($config->use_cronolog) {
        my $path     = $config->cronolog_path;
        my $log_file = $log_path . "/" . $config->cronolog_template;
        my $err_file = $log_file;
        $log_file =~ s/LOGFILE/access/;
        $err_file =~ s/LOGFILE/error/;

        my $log_params = $config->cronolog_params;
        $log_params =~ s/LOGDIR/$log_path/;
        my $err_params = $log_params;
        $log_params =~ s/LOGFILE/access/;
        $err_params =~ s/LOGFILE/error/;

        open $logfh, "|-", "$path $log_params $log_file"
          or die "Could not run $path: $!";

        unless ($self->errorlog_stderr) {
            open STDERR, "|-", "$path $err_params $err_file"
              or die "Could not run $path: $!";
        }

    }
    else {
        my $log_file = $log_path . "/access_log";
        my $err_file = $log_path . "/error_log";

        open $logfh, ">>", $log_file
          or die "Could not open $log_file: $!";

        unless ($self->errorlog_stderr) {
            open STDERR, ">>", $err_file or die $!;
        }
    }

    return $logfh;
}

sub reference {
    my $self = shift;

    my $app   = sub { $self->exec(@_) };
    my $logfh = $self->_logfh;

    $logfh->autoflush(1);
    STDERR->autoflush(1);

    my @trusted_ips = $config->proxyip_forwarders;
    @trusted_ips = () if grep { $_ eq '*' } @trusted_ips;

    builder {
        if ($config->apache_reload) {
            enable "Refresh", cooldown => 2;
        }
        enable "Plack::Middleware::XForwardedFor", (@trusted_ips ? (trust => \@trusted_ips) : ());
        enable_if { $_[0]->{PATH_INFO} ne "/combust-healthz" }
        "AccessLog",
          logger => sub { print $logfh @_ },
          format => qq{%h %V %u %t "%r" %>s %b "%{Referer}i" "%{User-agent}i" %{Request-ID}o};
        enable "Options";
        inner();
        $app;
    }
}

1;
