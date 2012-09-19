package Combust::Control;
use strict;
use Combust::Constant qw(OK SERVER_ERROR MOVED DONE DECLINED REDIRECT);
use Carp qw(confess cluck carp);
use Digest::SHA1 qw(sha1_hex);
use HTML::Entities ();
use Encode qw(encode_utf8);
use Scalar::Util qw(looks_like_number reftype);
use IO::Compress::Gzip qw(gzip $GzipError);

# TODO: figure out why we use this; remove it if possible
require bytes;

use Combust::Cache;
use Combust::Template;
use Combust::Cookies;
use Combust::Secret qw(get_secret);
use Combust::Config;

use namespace::clean;

use base qw(Combust::Redirect);

my $config = Combust::Config->new();

sub config { $config }

my $root = $config->root;

sub r {
  my $self = shift;
  # some day we'll deprecate this - it only works for Apache13 and Apache2
  return $self->request->_r;
}

sub req_param {
  my $self = shift;
  $self->request->req_param(@_);
}

sub param  { cluck "param() deprecated; use tpl_param()"; tpl_param(@_) }
sub params { cluck "params() deprecated; use tpl_params()"; tpl_params(@_) }

sub tpl_param {
  my ($self, $key) = (shift, shift);
  return unless $key;
  #Carp::cluck "param('$key' ...) called" if $key eq "user";
  $self->{params}->{$key} = shift if @_;
  return $self->{params}->{$key};
}

sub tpl_params {
  my $self = shift;
  cluck("tpl_params called with [$self] as self.  Did you configure the handler to call ->handler instead of ->super?")
    unless ref $self;
  cluck('Combust::Control->tpl_params called with parameters, did you mean to call "param"?') if @_;
  $self->{params} || {};
}

sub new {
  my ($class, $r) = @_;

  # return if we are already blessed
  return $class if ref $class;

  my $self = bless( { } , $class);
  
  $self;
}

sub super ($$) {
  my $class   = shift;
  my $r = shift;

  confess(__PACKAGE__ . '->super got called without $r') unless $r;
  return unless $r;

  my $self = $class->new($r);

  Combust::Notes::handler($r);

  $self->tt->set_include_path($self->get_include_path);

  my $status;

  eval {
    $status = OK;
    $status = $self->init if $self->can('init');
  };
  if ($@) {
    cluck "$self->init died: $@";
    return SERVER_ERROR;
  }
  return $status unless $status == OK;

  eval {
      ($status) = $self->handler($self->r);
  };
  cluck "Combust::Control: oops, class handler died with: $@" if $@;
  return SERVER_ERROR if $@;

  # should we do this to make it harder for people to shoot themselves in the foot?
  # $self->_cleanup_params;

  return $status;
}

sub handler {
  my $self = shift;
  unless ($self->can('render')) {
    my $msg = "$self doesn't have a render method; you probably got the inheritance order messed up somewhere.";
    warn $msg;
    die $msg;
  }

  my $redir_status = $self->redirect_check;
  return $redir_status unless $redir_status == DECLINED;

  my ($status, $output, $content_type) = $self->do_request();
  # have to return 'OK' and fake it with r->status or some such to make a custom 404 easily
  return $status unless $status == OK;
  my @r = $self->send_output($output, $content_type);
  if ($self->can('cleanup')) {
      eval { $self->cleanup };
      warn "CLEANUP method failed: $@" if $@; 
  }
  return @r;
}

sub do_request {
  my $self = shift;

  my $cache_info = $self->cache_info || {};

  my ($status, $output, $cache);

  if ($cache_info->{id} 
      && ($cache = Combust::Cache->new( type => ($cache_info->{type} || '') ))
     ) {
    my $cache_data;
    $cache_data = $cache->fetch(id => $cache_info->{id})
      unless $self->req_param('cache_bypass');

    if ($cache_data and $cache_data->{data}) {
      $self->post_process($cache_data->{data});
      $self->r->update_mtime($cache_data->{created_timestamp});
      my ($content_type);
      $content_type = $cache->{meta_data}->{content_type}
	if $cache->{meta_data}->{content_type};
      $status = $cache->{meta_data}->{status}
	if $cache->{meta_data}->{status};

      $status ||= OK;

      return ($status, $cache_data->{data}, $content_type);
    }
  }

  ($status, $output, my $content_type) = eval { $self->render };
  if (my $err = $@) {
      if ($err =~ m{^(-?\d+)($|\sat\s\/)}) {
          $status = $1;
      }
      else {
          warn "render failed: $err";
          $status = SERVER_ERROR;
      }
  }
  return $status unless $status == OK;

  # sometimes we end up here with "OK" but with no content ... gah.
  if ($cache and $output and $status != SERVER_ERROR and !$self->no_cache) {
    $cache_info->{meta_data}->{content_type} = $content_type if $content_type;
    $cache_info->{meta_data}->{status}       = $status || $self->r->status;
    $cache->store( %$cache_info, data => $output );
  }
  
  $status = $self->post_process($output);

  return ($status, $output, $content_type);
}

sub no_cache {
    my $self   = shift;
    my $status = shift;
    $self->{no_cache} = $status if defined $status;
    return $self->{no_cache};
}

sub cache_info {}
sub post_process { OK }

sub _cleanup_params {
  my $self = shift;
  for my $param (keys %{$self->{params}}) {
    delete $self->{params}->{$param};
  }
}

sub get_include_path {
  my $self = shift;

  my $r = $self->r;

  my $site = $self->site;
  unless ($site) {
    my @path = ("$root/apache/root_templates/");
    unshift @path, $r->document_root if $r->dir_config('UseDocumentRoot');
    return \@path;
  }

  my @site_dirs = split /:/, ($config->site->{$site}->{docs_site} || $site);

  #warn Data::Dumper->Dump([\$r], [qw(r)]);

  my $cookies = $self->cookies;

  my ($user);
  my $root_param = $self->request->req_param('root') || '';
  if (($user) = ($root_param =~ m!^/?([a-zA-Z]+)$!)) {
    $cookies->cookie('root', "$user");
  } 
  elsif ($root_param eq "/") {
    # don't set user, reset the cookie
    $cookies->cookie('root', "/");
  }
  elsif (($user) = (($cookies->cookie('root')||'') =~ m!^([a-zA-Z]+)$!)) {
    # ...  why is this in an elsif?  :-)
  }

  my $path;

  if ($user) {
    # FIXME|TODO: should expand on ~ instead of using /home
    $user = "/home/$user";
    my $docs = $config->docs_name;
    $path = [
	     (map { "$user/$docs/$_/" } @site_dirs),
	     "$user/$docs/shared/",
	     "$user/$docs/",
	    ];
  }
  else {
    my $root_docs = $config->root_docs;
    $path = [
	     (map { "$root_docs/$_/" } @site_dirs),
	     "$root_docs/shared/",
	     "$root_docs/",
	    ];
  }


  $path = [ $r->document_root ] if $r->dir_config('UseDocumentRoot');
  push @$path, "$root/apache/root_templates/";

  #warn Data::Dumper->Dump([\$path], [qw(path)]);
  
  return $path;

}

sub evaluate_template {
  my $self      = shift;
  my $template  = shift;

  my $tpl_params    = { %{$self->tpl_params }, ($_[0] and ref $_[0] eq 'HASH') ? %{$_[0]} : @_ };

  my $r = $self->r;

  local $tpl_params->{r} = $r;
  local $tpl_params->{notes} = $r->pnotes('combust_notes');
  local $tpl_params->{root} = $root;  # localroot anyone?
  local $tpl_params->{siteconfig} = $self->site && $self->config->site->{$self->site};

  local $tpl_params->{combust} = $self;

  local $tpl_params->{site} = $tpl_params->{site} || $self->site;

  my $output = eval { $self->tt->process($template, $tpl_params, { site => $tpl_params->{site} } ) };

  unless(defined $output) {
      my $err = $self->tt->error || $@;
      warn( (ref $self ? ref $self : $self) . "  - ". $r->uri . ($r->args ? '?' .$r->args : '')
            . " - error processing template $template: $err");
      die $err;
  }

  return $output;
}

my $ctemplate;

sub tt {
    my $self = shift;
    return $ctemplate ||= Combust::Template->new(@_)
      or die "Could not initialize Combust::Template object: $Template::ERROR";
}

sub provider {
    my $self = shift;
    cluck "combust->provider is deprecated; use combust->tt->provider";
    $self->tt->provider(@_);
}

sub site {
  my $self = shift;
  return $self->{site} if $self->{site};
  return $self->{site} = $self->r->dir_config("site");
}

sub content_type {
  shift->request->content_type(@_);
}

sub send_cached {
  my ($self, $cache, $content_type) = @_;

  $self->r->update_mtime($cache->{created_timestamp});

  $content_type = $cache->{meta_data}->{content_type}
      if $cache->{meta_data}->{content_type};

  return $self->send_output($cache->{data}, $content_type);
}

sub default_character_set {
  'utf-8'
}

sub send_output {
  my $self = shift;
  
  my $output = shift;
  my $content_type = shift || $self->content_type || 'text/html';

  unless (defined $output) {
    cluck "send_output called with undefined output";
    return 404;
  }

  # for some reason mod_perl will sometimes forget to dereference
  # a reference, so let's not try printing those anymore.
  $output = $$output if ref $output and reftype($output) ne 'GLOB';

  my $r = $self->r;

  $self->cookies->bake_cookies;

  # not that we actually have the /w3c/p3p.xml document
  $self->request->header_out('P3P',qq[CP="NOI DEVo TAIo PSAo PSDo OUR IND UNI NAV", policyref="/w3c/p3p.xml"]);

  my $length;
  if (ref($output) and reftype($output) eq "GLOB") {
    $length = ( stat($output) )[7]
      unless tied(*$output);    # stat does not work on tied handles
  }
  else {
    if ($content_type =~ m!^text/!) {

       # eek - this is certainly not correct, but seems to have worked for us...
        $output = encode_utf8($output);

        if (($self->request->header_in('Accept-Encoding') || '') =~ m/\bgzip\b/) {
            my $compressed;
            gzip \$output => \$compressed
              or die "gzip failed: $GzipError\n";
            $output = $compressed;

            $self->request->header_out('Content-Encoding' => 'gzip');
            $self->request->header_out(
                'Vary' => join ", ",
                grep {$_} $self->request->header_out('Vary'), 'Accept-Encoding'
            );

        }
    }

      # length in bytes
      $length = do { use bytes; length($output) };
  }

  $self->request->update_mtime(time) if $r->mtime == 0; 
  
  $r->set_last_modified();  # set's to whatever update_mtime told us..

  $self->request->header_out('Content-Length' => $length)
    if defined $length;

  # defining the character set helps in handling the CERT advisory
  # regarding  "cross site scripting vulnerabilities" 
  #   http://www.cert.org/tech_tips/malicious_code_mitigation.html
  $content_type .= "; charset=" . $self->default_character_set
    if $content_type =~ m/^text/ and $content_type !~ m/charset=/;
  $self->content_type($content_type);
  #warn "content_type: $content_type";

  if ((my $rc = $r->meets_conditions) != OK) {
    # this didn't work with just returning $rc -- need to check if it works now.
    $r->status($rc);
    return $rc;
  }

  $self->request->send_http_header($content_type);

  #warn Data::Dumper->Dump([\$output], [qw(output)]);

  # if all that is requested is HEAD
  # don't send the body
  return OK if $r->header_only;

  if (ref($output) and reftype($output) eq "GLOB") {
    my $buffer;
    while(read($output,$buffer,40960)) {
      print $buffer;
    }
  }
  else {
    print $output;
  }

  # TODO: need to get the status from further up the chain and return it correctly here.
  return OK;
}

sub redirect {
  my $self = shift;
  my $url = shift;
  my $ref_url = ref $url || '';
  if ($ref_url =~ m/^Apache/) {  # if we got passed an $r as the first parameter
    cluck "You don't need to pass \$r to the redirect method";
    $url = shift;
  }

  my $permanent = shift;

  $url = $url->abs if ref $url =~ m/^URI/;

  # this should really check for a complete URI or some such; we'll do
  # that when it breaks on a ftp:// or whatever redirect :-)
  unless ($url =~ m!^https?://!i) {
    $url = $config->base_url($self->site) . $url;
  }

  #use Carp qw(cluck);
  #warn "redirecting to [$url]";

  $self->request->header_out('Location' => $url);
  $self->r->status($permanent ? MOVED : REDIRECT);

  my $url_escaped = HTML::Entities::encode_entities($url);

  my $data = <<EOH;
<!DOCTYPE HTML PUBLIC "-//IETF//DTD HTML 2.0//EN">
<HTML><HEAD><TITLE>Redirect...</TITLE></HEAD><BODY>The document has moved <A HREF="$url_escaped">here</A>.<P></BODY></HTML>
EOH

  # allow setting custom headers etc - this doesn't bail out if the
  # status is wrong, unlike on the regular requests. (Just because we
  # don't care for that feature anyway).
  $self->post_process( $data );

  $self->send_output( $data, 'text/html' );
  return DONE;
}

sub cookies {
  my $self = shift;
  my $cookies = $self->request->notes('cookies');
  return $cookies if $cookies;
  $cookies = Combust::Cookies->new($self->request,
                                   # Combust::Request defaults this to r->hostname
                                   # if it is not set
                                   domain => ($self->site && $self->config->site->{$self->site}->{cookie_domain} || ''),
                                  );
  $self->request->notes('cookies', $cookies);
  return $cookies;
}

sub cookie {
  my $self = shift;
  $self->cookies->cookie(@_);
}

sub auth_token {
    my $self = shift;
    return $self->{_auth_token} if $self->{_auth_token};
    my $cookie = $self->cookie('uiq');
    my ($time, $uid) = split /-/, $cookie || '';
    # reset the auth_token twice a day
    $self->cookie('uiq', time . '-' . sha1_hex(time . rand)) unless $time and $time > time - 43200;
    return $self->{_auth_token} = _calc_auth_token( $self->cookie('uiq') );
}

sub _calc_auth_token {
    my $cookie = shift;
    my ($time, $uid) = split /-/, $cookie;
    # let the old auth tokens be good for up to a day
    ($time, my $secret) = get_secret(type => 'auth_token', time => $time, expires_at => $time + 86400 );
    return '2-' . sha1_hex( $secret . $cookie);
}

sub check_auth_token {
    my $self = shift;
    my $token_param = $self->req_param('auth_token') or return 0;
    return $token_param eq $self->auth_token;
}


# default api_class tries to guess what you wanted
sub api_class {
    my $class = shift;
    my ($api_class) = $class =~ m/^([^:]+)/;
    return "${api_class}::API" unless $api_class eq 'Combust';
    die 'api_class not defined in your controller';
}

sub api {
    my ($self, $method, $params, $args) = @_;

    my $api_params = {
             params   => $params,
             ($args ? (%$args) : ()),
       };

    if ( !exists $api_params->{user} and $self->can('user') ) {
        $api_params->{user} = $self->user;
    }

    return $self->api_class->call
      ($method,
       $api_params,
      );
}

sub deployment_mode {
    my $self = shift;
    my $dm = $self->config->site->{$self->site}->{deployment_mode} || 'test';
    warn "INVALID deployment_mode CONFIG for ", $self->site, "! Use devel, test or prod\n" unless $dm =~ m/^(devel|test|prod)$/;
    $dm;
}

sub request {
  my $self = shift;
  return $self->{_request} if $self->{_request};
  # should we pass any parameters to the request class when we open it up? Hmn.
  $self->{_request} = $self->request_class->new;
}

my $request_class;
sub request_class {
  return $request_class if $request_class;
  my $class = shift;
  $request_class = $class->pick_request_class;
  eval "require $request_class";
  die qq[Could not load "$request_class": $@] if $@;
  $request_class;
}

sub pick_request_class {
  my ( $class, $request_class ) = @_;

  return 'Combust::Request::' . $request_class if $request_class;
  return "Combust::Request::$ENV{COMBUST_REQUEST_CLASS}" if $ENV{COMBUST_REQUEST_CLASS};

  if ($ENV{MOD_PERL}) {
    my ($software, $version) = $ENV{MOD_PERL} =~ /^(\S+)\/(\d+(?:[\.\_]\d+)+)/;
    if ($software eq 'mod_perl') {
      $version =~ s/_//g;
      $version =~ s/(\.[^.]+)\./$1/g;
      return 'Combust::Request::Apache2' if $version >= 2.000001;
      return 'Combust::Request::Apache13'  if $version >= 1.29;
      die "Unsupported mod_perl version: $ENV{MOD_PERL}";
    }
    else {
      die "Unsupported mod_perl: $ENV{MOD_PERL}"
    }
  }

  return 'Combust::Request::CGI';
}


1;
