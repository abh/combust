package Combust::ApacheConfig::Role;
use Moose::Role;

has 'apache_config_file' => (
    is      => 'ro',
    isa     => 'Str',
    default => sub {
        my $work_path = Combust::Config->new->work_path;
        return $work_path . '/httpd.conf';
    }
);

has 'apache_config' => (
    is         => 'rw',
    isa        => 'HashRef',
    lazy_build => 1,
);

sub _build_apache_config {
    my $self = shift;

    $self->generate_apache_configuration;

    my $config = Config::General->new(
        -ConfigFile       => $self->apache_config_file,
        -ApacheCompatible => 1
    );

    my %config = $config->getall;

    return \%config;
}

sub generate_apache_configuration {
    my $self = shift;

    use Combust::Config;
    use Template;

    my $config = Combust::Config->new();

    my $dir = "$ENV{CBROOT}/apache/conf/";
    my @local_dir =
      $ENV{CBROOTLOCAL}
      ? ("$ENV{CBROOTLOCAL}/apache/conf", "$ENV{CBROOTLOCAL}/apache")
      : ();

    my $include_path = [];
    push @$include_path, @local_dir if @local_dir;
    push @$include_path, $dir;

    my $tt = new Template(
        {   INCLUDE_PATH => $include_path,
            RELATIVE     => 0,
            ABSOLUTE     => 1,
            EVAL_PERL    => 1,
        }
    ) or die "Error: $Template::ERROR\n";
    $Template::ERROR = '' if 0;

    my $params = {
        config       => $config,
        root         => $ENV{CBROOT},
        root_local   => ($ENV{CBROOTLOCAL} || ''),
        root_default => ($ENV{CBROOTLOCAL} || $ENV{CBROOT}),
        PH           => 'PerlResponseHandler',
        plack        => 1,
    };

    $params->{dont_edit} = <<EOT;
# ========================================================================
# THIS FILE IS AUTOGENERATED.  DO NOT EDIT.  YOUR CHANGES WILL GO BYE BYE!
# ========================================================================
EOT

# setup $conf/$params for the template

    my $work_path = $config->work_path;

    $tt->process("httpd2.tmpl", $params, $self->apache_config_file)
      or die "Template Error: " . $tt->error();

}

1;
