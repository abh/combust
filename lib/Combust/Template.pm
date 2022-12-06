package Combust::Template;
use strict;

use Template;
use Template::Parser;
use Template::Stash;

# use Template::Constants split /\|/, 'DEBUG_VARS|DEBUG_DIRS|DEBUG_STASH|DEBUG_PARSER|DEBUG_PROVIDER|DEBUG_SERVICE|DEBUG_CONTEXT';

use Carp qw(croak);
use Scalar::Util;

use Combust::Config;

use Combust::Template::Provider;
use Combust::Template::Filters;
use Combust::Template::Translator::POD;

my $config = Combust::Config->new();
my $root   = $config->root;

$Template::Config::STASH = 'Template::Stash::XS';

$Template::Stash::SCALAR_OPS->{rand} = sub {
    return int(rand(shift));
};

sub new {
    my $class = shift;
    my $obj   = bless {}, $class;
    return $obj->_init(@_);
}

sub _init {
    my $self = shift;
    my %args = ref $_[0] ? %{$_[0]} : @_;

    my $parser = Template::Parser->new();

    my %provider_config = (
        PARSER      => $parser,
        COMPILE_EXT => '.ttcache',
        COMPILE_DIR => $config->work_path . "/ctpl",
        UNICODE     => 1,
        ENCODING    => 'utf-8',

        #TOLERANT => 1,
        #RELATIVE => 1,
        CACHE_SIZE => 128,    # cache 128 templates
        EXTENSIONS => [
            {   extension  => "pod",
                translator => Combust::Template::Translator::POD->new()
            },
        ],

    );

    Scalar::Util::weaken(my $weak_self = $self);
    my $provider =
      Combust::Template::Provider->new(%provider_config,
          INCLUDE_PATH => [sub { $weak_self->get_include_path }],);

    my %tt_config = (
        FILTERS => {
            'navigation' => [\&Combust::Template::Filters::navigation_filter_factory, 1],
            $args{filters} ? %{$args{filters}} : ()
        },

        PLUGINS => ($args{plugins} || {}),

        RELATIVE       => 1,
        LOAD_TEMPLATES => [$provider],

        #'LOAD_TEMPLATES' => [ $file, $http ],
        #PREFIX_MAP => {
        #               file => 0,
        #               http => 1,
        #		    default => 1,
        #	            },
        'PRE_PROCESS' => ['tpl/combust_defaults', 'tpl/defaults'],
        'PROCESS'     => 'tpl/wrapper',
        'PLUGIN_BASE' => 'Combust::Template::Plugin',

        # 'DEBUG'  => DEBUG_VARS | DEBUG_DIRS | DEBUG_STASH
        #             | DEBUG_PARSER | DEBUG_PROVIDER | DEBUG_SERVICE
        #             | DEBUG_CONTEXT,
    );

    if ($config->template_timer) {
        require Template::Timer;
        $tt_config{CONTEXT} = Template::Timer->new(%tt_config);
    }

    $self->{provider} = $provider;

    $self->{tt} = Template->new(\%tt_config)
      or croak "Could not initialize Template object: $Template::ERROR";

    return $self;
}

sub error {
    shift->{tt}->error;
}

sub provider {
    shift->{provider};
}

sub set_include_path {
    my $self = shift;
    $self->{inc_path} = shift;
}

sub get_include_path {
    my $self = shift;

    if (my $inc_path = $self->{inc_path}) {
        return $inc_path     if ref $inc_path eq 'ARRAY';
        return $inc_path->() if ref $inc_path eq 'CODE';
        croak "Don't know how to process include_path $inc_path";
    }
    else {
        return $self->default_include_path;
    }
}

sub default_include_path {
    my $self = shift;

    # evil evil; duplication from Combust::Control::get_include_path

    my $site      = $self->{_site};
    my $root_docs = $config->root_docs;
    my $site_dir =
      ($site and $config->site->{$site}->{docs_site})
      ? $config->site->{$site}->{docs_site}
      : $site;

    my $path = [
        (   $site_dir
            ? ("$root_docs/$site_dir/")
            : ()
        ),
        "$root_docs/shared/",
        "$root_docs/",
        "$root/apache/root_templates/",
    ];

    $path;
}

sub process {
    my ($self, $template, $tpl_params, $args) = @_;

    local $self->{_site} = $args->{site};

    $tpl_params->{config} = $config unless $tpl_params->{config};

    my $output;
    unless ($self->{tt}->process($template, $tpl_params, \$output, {binmode => ":utf8"})) {
        die $self->{tt}->error . "\n";
    }

    # XXX:  Why does $output not get UTF8 bit set correctly ??
    utf8::decode($output) || utf8::upgrade($output);

    return $output;
}

1;
