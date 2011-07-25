package Combust::Control::API;
use strict;
use base qw(Combust::Control);
use Combust::Constant qw(OK NOT_FOUND);
use JSON::XS qw(encode_json);
use Sys::Hostname qw(hostname);
use Return::Value;

sub render {
    my $self = shift;
    my ($uri, $method) = ($self->request->uri =~ m!^(/api/((\w+)/?([a-z]\w+))?)!);
    return 404 unless $method;

    # MSIE caches POST requests sometimes (?)
    $self->no_cache(1) if $self->request->method eq 'post';
    
    if ($self->can('check_auth')) {
        unless (my $auth_setup = $self->check_auth($method)) {
            return $self->system_error(412, "$auth_setup" || 'Authentication failure');
        }
    }

    my $api_options = eval { $self->api_options } || {};
    if (my $err = $@) {
        return $self->system_error(500, $err);
    }
    
    my ($result, $meta) = eval {
        $self->api($method, $self->api_params, { json => 1, %$api_options });
    };
    if (my $err = $@) {
        return $self->system_error(500, $err);
    }
    
    return $self->system_error(500, "$uri didn't return a result") unless (defined $result);

    return OK, $result, 'text/javascript';
}

sub api_params {
    shift->request->req_params;
}

sub api_options {
    return {};
}

sub _format_error {
    my $self = shift;
    my $status = shift; 
    my $time = scalar localtime();

    my $time = DateTime->now->iso8601;
    chomp(my $err = join(" ", $time, @_));

    warn "ERROR: $err\n" if $self->deployment_mode eq 'devel';

    encode_json(
        {   ($status >= 500 ? "system_error" : "error") => $err,
            server   => hostname,
            datetime => $time,
        }
    );
}

sub system_error {
    my $self = shift;
    my $status = shift || 500;
    $self->request->response->status($status);
    return 200, $self->_format_error($status, @_), 'text/javascript';
}

# todo: should these be in Combust::Control ?
sub no_cache {
    my $self = shift;
    my $status = shift;
    $status = 1 unless defined $status;
    $self->{no_cache} = $status;
}

sub post_process {
    my $self = shift;

    if ($self->{no_cache}) {
        my $r = $self->request;

        $r->header_out('Expires', HTTP::Date::time2str( time() ));
        $r->header_out('Cache-Control', 'private, no-store, no-cache, must-revalidate, post-check=0, pre-check=0');
        $r->header_out('Pragma', 'no-cache');
    }
    
    return OK;
}



1;


