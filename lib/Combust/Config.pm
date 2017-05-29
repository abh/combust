package Combust::Config;
use strict;
use Config::Simple;
use Data::Dumper qw();
use Sys::Hostname qw(hostname);
use Carp qw(carp croak cluck);
use Socket qw(inet_ntoa);

my $file = $ENV{CBCONFIG} ? $ENV{CBCONFIG}
           : $ENV{CBROOTLOCAL} ? "$ENV{CBROOTLOCAL}/combust.conf"
           : $ENV{CBROOT} ? "$ENV{CBROOT}/combust.conf"
           : croak 'Could not find combust.conf, did you set $ENV{CBROOT} / $ENV{CBROOTLOCAL}?';

my $cfg = new Config::Simple($file) or die Config::Simple->error();

my %Config = $cfg->vars();
#warn Data::Dumper->Dump([\$cfg],[qw(cfg)]);
#warn Data::Dumper->Dump([\%Config],[qw(Config)]);

my %dbs = _setup_dbs();  

sub _setup_dbs {

  croak "Old database configuration detected, you must update the syntax. See combust.conf.sample" 
    if $cfg->param('db_data_source');

  my %sections = map { $_ =~ s/^database-(.*?)\..*/$1/; $_ => 1 } grep { m/^database/ } keys %Config;
  my $got_default = 0;
  foreach my $section (keys %sections) {
    my $db_name = $section; 
    my $db_config  = $cfg->param(-block => "database-$section"); 
    $db_config->{name} = $section;
    $dbs{default}  = $db_config and $got_default++ if $db_config->{default};
    $dbs{$db_name} = $db_config;
  }

  unless ($got_default) {
    if (scalar (grep { !$dbs{$_}->{alias} } keys %dbs) > 1) {
      croak 'You defined more than one database but didn\'t mark one of them "default=1"';
    }
    else {
      my ($db_name) = grep { !$dbs{$_}->{alias} } keys %dbs;
      $dbs{default} = $dbs{$db_name} if $db_name;
    }
  }

  %dbs;
}  

my $singleton;

sub new {
  return $singleton if $singleton;
  $singleton = shift->_new(@_);
}

sub _new {
  my ($class, %args) = (shift, @_);
  bless( {}, $class);
}

sub config_file {
    my $self = shift;
    croak "can't set config_file()" if @_;
    $file;
}

sub site {
  my $self = shift;
  return $self->{_site} if $self->{_site};
  my $h = {};

  for my $site ($self->sites_list) {
    my $sd = $cfg->param(-block=>$site);
    # FIXME: should resolve refs and stuff ...
    $h->{$site} = $sd;
  }

  $self->{_site} = $h; 
}

sub sites_list { 
  my $sites = $cfg->param('sites');
  my  $vars = $cfg->vars;
  unless ($sites) {
      $sites = [ grep { my $b = $cfg->param(-block => $_);
                        $b->{disabled} ? 0 : 1;
                      }
                 grep { $_ !~ m/^database/ and $_ !~ m/^(default|apache)$/ }
                 sort $cfg->get_block() 
               ];
  }
  ref $sites ? @$sites : ($sites);
}

sub sites {
  my $self = shift;
  # grep for non-configured sites?
  +{ map { $_ => $self->site->{$_} } $self->sites_list };
}

sub servername {
  $cfg->param('servername') || hostname || 'combust-server';
}

sub port {
  $cfg->param('port') || 8225;
}

sub external_port {
  # should we default to $self->port instead of undef (and then require port 80 to be 
  # configured when you use a proxy?)
  $cfg->param('external_port') || undef;
}

sub external_protocol {
  $cfg->param('external_protocol') || undef;
}

sub proxyip_forwarders {
  my $allow = $cfg->param('proxyip_forwarders') || "127.0.0.1";
  ref $allow ? @$allow : ($allow);
}

sub base_url {
  my $self = shift;
  my $sitename = shift or carp "sitename parameter required" and return;
  carp "no [$sitename] site configured" and return unless $self->site->{$sitename};
  my $site = $self->site->{$sitename};
  my $servername = $site->{servername};
  unless ($servername) {
      cluck "servername not defined for site [$sitename]";
      return;
  }
  my $port = $self->site->{$sitename}->{port} || $self->external_port || 80;
  my $protocol = 'http';
  $protocol = 'https' if $port and $port == 443;
  $protocol = $self->external_protocol if $self->external_protocol;
  my $base_url = "$protocol://$servername" . 
    ((($protocol eq 'http' and $port == 80) or ($protocol eq 'https' and $port == 443))
      ? ''
      : ":$port");
  return $base_url;
}

sub database_names {
   my $self = shift;
   sort keys %dbs;
}

sub database {
  my ($self, $db_name) = @_;
  carp "No databases configured in the combust configuration" and return unless %dbs; 

  $db_name ||= 'default';

  $db_name = $self->_resolve_db_alias($db_name);
  
  unless ($db_name and $dbs{$db_name}) {
    cluck "no database $db_name defined, using default" if $db_name;
    $db_name = 'default';
    $db_name = $self->_resolve_db_alias($db_name);
  }
  $dbs{$db_name};
}

sub _resolve_db_alias {
  my ($self, $db_name) = @_;
  if ($dbs{$db_name} and $dbs{$db_name}->{alias}) {
    return $dbs{$db_name}->{alias};
  }
  return $db_name;
}

sub db_data_source { shift->database->{data_source}; }
sub db_password    { shift->database->{password};    }
sub db_user        { shift->database->{user};        }

sub apache_reload {
  # maybe this should have been reversed
  $cfg->param('apache_reload') || 0;
}

sub apache_dumpheaders {
  $cfg->param('apache_dumpheaders') || 0;
}

sub template_timer {
  $cfg->param('template_timer') || 0;
}

sub reload_langfiles {
  $cfg->param('reload_langfiles') || 0;
}

# cronolog settings
# {{{

sub use_cronolog {
  $cfg->param('use_cronolog') || 0;
}

sub cronolog_path {
  $cfg->param('cronolog_path') || "/usr/sbin/cronolog";
}

sub cronolog_template {
  $cfg->param('cronolog_template') || "%Y/%m/LOGFILE.%Y%m%d";
}

sub cronolog_params {
  $cfg->param('cronolog_params') || "-l LOGDIR/LOGFILE.latest";
}


# }}}

sub apache_root {
  my $root = $cfg->param('apache_root');
  unless (defined $root) {
    ($root = $_[0]->httpd) =~ s!/s?bin/httpd$!!;
  }
  $root;
}

sub modperl_path {
  $cfg->param('modperl_path');
}

sub log_path {
  my $self = shift;
  my $path = $cfg->param('log_path') || $self->root_local . '/logs';
  $path =~ s!/$!!;
  $path;
}

sub work_path {
  my $self = shift;
  my $path = $cfg->param('work_path') || $self->root_local . '/tmp';
  $path =~ s!/$!!;
  $path
}

sub httpd {
  $cfg->param('httpd') || '/usr/sbin/httpd';
}

sub perl {
  $cfg->param('perl');
}

sub scaffold_class {
  $cfg->param('scaffold_class');
}

sub apache_libexec {
  $cfg->param('apache_libexec');
}


#sub config {
#  $cfg;
#}

sub root {
  $ENV{CBROOT};
}

sub root_local {
  $ENV{CBROOTLOCAL} || $ENV{CBROOT};
}

sub root_docs {
  my $self = shift;
  $ENV{CBDOCS} || $cfg->param('docs') || ($self->root_local . "/" . $self->docs_name);
}

sub docs_name {
  $cfg->param('docs_name') || 'docs';
}

sub job_servers {
  my $self = shift;
  my $port = $self->job_server_port;
  my $js = $cfg->param('job_servers') || "127.0.0.1";
  my @js = ref $js ? @$js : ($js);
  map { $_ =~ m/:/ ? $_ : "$_:$port" } @js;
}

sub job_server_port {
  $cfg->param('job_server_port') || "7003";
}

sub memcached_servers {
  my $self = shift;
  my $ms = $cfg->param('memcached_servers') || "127.0.0.1:11211";
  my @ms = ref $ms ? @$ms : ($ms);
  map {
    my ($s,$p) = split /\@/;
    unless ( $s =~ /^[\d\.]+:/) {
      my ($host,$port) = split /:/, $s;
      my $ipn = gethostbyname($host) or die "Cannot resolve memcache hostname '$host'\n";
      my $ip = inet_ntoa($ipn);
      $s = $ip . ":" . $port;
    }
    $p ? [$s,$p] : $s
  } @ms;
}


# apache configuration

sub maxclients          { $cfg->param('apache.maxclients')      || 20 }
sub keepalive {
    my $k = $cfg->param('apache.keepalive');
    return ($k and lc $k ne 'off') ? 1 : 0;
}
sub keepalivetimeout    { $cfg->param('apache.keepalivetimeout')|| 300 }
sub startservers        { $cfg->param('apache.startservers')    || 5 }
sub minspareservers     { $cfg->param('apache.minspareservers') || 1 }
sub maxspareservers     { $cfg->param('apache.maxspareservers') || 10 }
sub maxrequestsperchild { $cfg->param('apache.maxrequestsperchild') || 500 }

sub apache_modules {
  my $self = shift;

  my @default = $self->apache_version < 2 
    ? qw(env mime_magic mime negotiation status 
         autoindex dir cgi alias rewrite access auth setenvif)
    : qw(log_config alias env status deflate logio authn_file
         authz_host rewrite mime);

  my $add = $cfg->param('apache.modules_add');
  my $del = $cfg->param('apache.modules_del');
  my $modules = 
    $cfg->param('apache.modules') || 
      join(",", @default, ref $add ? @$add : ($add));
  my %modules_del = map { $_ => 1 } (ref $del ? @$del : ($del));
  return grep { !exists $modules_del{$_} } split /,/, $modules;
}

sub apache_version {
  my ($self, $version) = @_;
  $self->{apache_version} = $version if defined $version;
  return defined $self->{apache_version} ? $self->{apache_version} : 1.0;
}

sub apache_loglevel {
  $cfg->param('apache.loglevel') || "info";
}

sub static_headers {
  my $self = shift;
  my $sitename = shift or carp "sitename parameter required" and return;
  my %headers = (
    %{$cfg->get_block("headers-global")},
    %{$cfg->get_block("headers-${sitename}")});
  return %headers;
}

1;

