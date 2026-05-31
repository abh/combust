package Combust::Cookies;
use strict;
use URI::Escape qw(uri_escape_utf8 uri_unescape);

our $DEBUG = 0;

my $default_cookie_name = 'c';

my %special_cookies         = ();
my %special_cookies_reverse = ();

# put the "root" cookie into the "r" browser cookie
__PACKAGE__->add_special_cookie("root" => "r");

sub _setup_special_cookies_reverse {
    for my $cookie_name (keys %special_cookies) {
        for my $cookie (@{$special_cookies{$cookie_name}}) {
            $special_cookies_reverse{$cookie} = $cookie_name;
        }
    }
}

sub add_special_cookie {
    my ($class, $cookie, $cookie_name) = @_;
    $special_cookies{$cookie_name} ||= [];
    push @{$special_cookies{$cookie_name}}, $cookie;
    _setup_special_cookies_reverse();
}

sub new {
    my $proto = shift;
    my $class = ref $proto || $proto;
    my $r     = shift;
    my %args  = @_;
    my $self  = bless(
        {   request => $r,
            domain  => $args{domain}
        },
        $class
    );
    return $self;
}

sub request { shift->{request} }

sub changed {
    my ($self, $cookie, $val) = @_;
    $cookie ||= $default_cookie_name;

    #$self->{_changed} = {} unless $self->{_changed};
    $self->{_changed}->{$cookie} = $val if $val;
    return $self->{_changed}->{$cookie} || 0;
}

sub parse_cookies {
    my ($self) = @_;

    return $self->{_parsed} if $self->{_parsed};

    my $parsed = {};

    for my $cookie_name ($default_cookie_name, keys %special_cookies) {
        my $cookie = $self->request->cookies->{$cookie_name};
        next unless $cookie;

        $cookie =~ s/\r$// if $cookie;    # remove occasional trailing ^M

        $cookie = check_cookie($cookie_name, $cookie);

        warn "got cookie: [$cookie_name]=[$cookie]" if $DEBUG;

        # FIXME: we are unescaping the keys too... hmn
        $parsed = {%$parsed, map { uri_unescape($_) } split /\/~/, $cookie} if defined $cookie;

        $self->update_last_refreshed($cookie_name, $parsed);
    }
    return $self->{_parsed} = $parsed;
}

sub update_last_refreshed {
    my ($self, $cookie_name, $cookies, $force) = @_;

    # $cookies ||= $self->parse_cookies;

    my $last_refreshed = $cookies->{"LR" . $cookie_name} || 0;
    if ($force or $last_refreshed < (time - (86400 * 7))) {
        $cookies->{"LR" . $cookie_name} = time;
        $self->changed($cookie_name, 1);
    }
}

sub cookie {
    my ($self, $cookie, $val) = @_;

    warn Data::Dumper->Dump([\$self], [qw(cookie_self)]) if $DEBUG > 1;

    my $cookies = $self->parse_cookies;

    if (defined $val and (!$cookies->{$cookie} or $cookies->{$cookie} ne $val)) {

        #warn "Setting $cookie to [$val]\n";
        $cookies->{$cookie} = $val;
        delete $cookies->{$cookie} if $val eq '';
        $self->changed($special_cookies_reverse{$cookie} || $default_cookie_name, 1);
    }
    defined $cookies->{$cookie} ? $cookies->{$cookie} : '';
}

sub bake_cookies {
    my $self = shift;

    # Legacy signed-blob cookies (c/r) are decommissioned: never write them.
    # TRANSITIONAL: expire any a browser still presents so they stop being
    # sent. This loop can be removed once legacy c/r cookies have aged out of
    # the field. (expires => 1 is epoch 1970, i.e. delete-now.)
    for my $cookie_name ($default_cookie_name, keys %special_cookies_reverse) {
        next unless $self->request->cookies->{$cookie_name};
        $self->request->set_cookie(
            $cookie_name, '',
            {expires => 1, domain => $self->{domain}, path => '/'}
        );
    }
    1;
}

sub check_cookie {
    my ($cookie_name, $raw_id) = @_;

    # Legacy signed-blob cookies are decommissioned; never verify/trust them.
    return '' unless wantarray;
    return ('', 'disabled', 0);
}

1;
