package Combust::StaticFiles;
use strict;
use List::Util qw(first max);
use JSON::XS ();
use Carp qw(cluck croak);
use Combust::Config;
use Cwd qw(getcwd);
use Storable qw(nstore);
use DBI ();    # for DBI::hash

use namespace::clean;

my $config            = Combust::Config->new;
my $startup_time      = time;
my $static_file_paths = {};
my $json              = JSON::XS->new->relaxed(1);

my %singletons;

sub new {
    my $proto = shift;
    my %args  = (

        # defaults go here ...
        @_,
    );

    croak "site or setup parameter required"
      unless $args{site} or $args{setup};

    return $singletons{$args{site}} if $args{site} and $singletons{$args{site}};

    my $self = bless \%args, $proto;

    # in development we always rebuild the data
    if ($self->deployment_mode eq 'devel') {
        $self->build();
    }

    unless ($self->{setup}) {
        my @sites = $config->sites_list;
        for my $site (@sites) {
            $self->setup_static_files($site);
        }
    }

    $singletons{$args{site}} = $self if $args{site};

    return $self;
}

sub deployment_mode {
    my $self = shift;
    return $config->site->{$self->site}->{deployment_mode} || 'test';
}

sub find_static_path {
    my ($self, $site) = @_;
    my $root_dir = $config->root_docs;

    my @static_dirs =
      ($root_dir . "/$site/static", $root_dir . "/static", $root_dir . "/shared/static",);
    return first { -e $_ && -d _ } @static_dirs;
}

sub setup_static_files {
    my ($self, $site) = @_;

    my $static_directory = $self->find_static_path($site);
    return unless $static_directory;

    $static_file_paths->{$site}->{path} = $static_directory;

    my $static_files = eval { retrieve("${static_directory}/.static.versions.store") }
      || $self->_load_json("${static_directory}/.static.versions.json");

    # TODO: in devel deployment mode we should reload this
    # automatically when the .json file changes
    my $static_groups_file = "${static_directory}/.static.groups.json";
    my $static_groups      = -r $static_groups_file && $self->_load_json($static_groups_file) || {};

    # no relative filenames in the groups
    for my $name (keys %$static_groups) {
        my $group = $static_groups->{$name};
        $group->{files} = [map { $_ =~ m!^/! ? $_ : "/$_" } @{$group->{files}}];
    }

    $static_file_paths->{$site}->{groups} = $static_groups;
    $static_file_paths->{$site}->{files}  = $static_files;
}

sub _load_json {
    my ($self, $file) = @_;
    return {} unless -r $file;
    my $data = eval {
        local $/ = undef;
        open my $fh, $file or die "Could not open $file: $!";
        my $versions = <$fh>;
        return $json->decode($versions);
    };
    warn $@ if $@;
    return $data;
}

sub _save_json {
    my ($self, $file, $data) = @_;
    my $json = $json->encode($data);
    open my $fh, '>', $file or die "could not open $file: $!";
    print $fh $json;
    close $fh or die "Could not close $file: $!";
}

sub static_file_paths {
    my $self = shift;
    return $static_file_paths->{$self->site} || {};
}

sub static_base {
    my ($self, $site) = @_;
    $site = $site || $self->site;
    my $base = $config->site->{$site} && $config->site->{$site}->{static_base};
    $base ||= '/static';
    $base =~ s!/$!!;
    $base;
}

sub static_base_ssl {
    my ($self, $site) = @_;
    $site = $site || $self->site;
    my $base = $config->site->{$site} && $config->site->{$site}->{static_base_ssl};
    return $self->static_base($site) unless $base;
    $base =~ s!/$!!;
    $base;
}

sub static_group {
    my ($self, $name) = @_;
    my $data = $self->static_group_data($name);
    return unless $data;
    return "/.g/$name" if $self->deployment_mode ne 'devel';
    return @{$data->{files}};
}

sub static_group_data {
    my ($self, $name) = @_;
    my $groups = $self->static_file_paths->{groups};
    return $groups && $groups->{$name};
}

sub static_groups {
    my $self   = shift;
    my $groups = $self->static_file_paths->{groups};
    return () unless $groups;
    return sort keys %$groups;
}

sub site { return shift->{site} }

sub static_url {
    my ($self, $file) = @_;
    $file or cluck "no filename specified to static_url" and return "";
    $file = "/$file" unless $file =~ m!^/!;

    my $regexp = qr/(\.(js|css|gif|png|jpg|svg|htc|ico))$/;

    my $file_attr;

    if ($file =~ m/$regexp/ and my $static_files = $static_file_paths->{$self->site}) {
        my $version;
        if ($self->deployment_mode eq 'devel') {
            my $static_directory = $static_files->{path};

            #warn "STAT: ${static_directory}$file - ", (stat("${static_directory}$file"))[9]
            #  if $file =~ m/graphs.server/;

            my $build_time = (@{$static_files->{files}->{"..build.time"}})[0];
            my $file_time  = (stat("${static_directory}$file"))[9];

            if ($build_time > $file_time) {
                if (ref $static_files->{files}->{$file}) {
                    ($version, $file_attr) = (@{$static_files->{files}->{$file}});
                }
            }
            if (!$version or $version =~ /^M-/) {
                $version = max($startup_time, $file_time);
            }
        }
        elsif (ref $static_files->{files}->{$file}) {
            ($version, $file_attr) = (@{$static_files->{files}->{$file}});
        }

        if ($file_attr and $file_attr->{min}) {
            $file =~ s!$regexp!-min$1!;
        }

        $file =~ s!$regexp!.v$version$1! if $version;
    }

    return $self->static_base($self->site) . $file;
}

sub build {
    my $static = shift;
    my $config = Combust::Config->new;

    my $root     = $ENV{CBROOTLOCAL};
    my $root_dir = $config->root_docs;

    my @sites = $config->sites_list;

    my %paths_done;

    for my $site (@sites) {
        my $now = time;
        my $dir = $static->find_static_path($site);
        next unless $dir;
        next if $paths_done{$dir}++;

        my $deployment_mode = $config->site->{$site}->{deployment_mode} || 'test';

        my $storable_file = "$dir/.static.versions.store";
        my $json_file     = "$dir/.static.versions.json";
        if (-e $json_file && !-w $json_file) {

            # it's not clear why this is a good idea; probably
            # the deployment script should decide if it wants
            # to run this or not ...
            warn "$json_file not writable, skipping\n";
            next;
        }

        chdir $dir or die "could not chdir to $dir";

        my $files = {};

        if (-d "$root/.svn") {
            my $svn   = `svn info -R`;
            my @files = map {
                +{map { chomp; split /: /, $_, 2 } split /\n/}
            } split /\n\n/, $svn;
            for my $file (@files) {
                $files->{"/" . $file->{Path}} = $file->{"Last Changed Rev"};
            }
        }
        elsif (-d "$root/.git") {
            $files = _get_git_tree($root, $dir);
        }
        else {
            warn "Could not find .svn or .git directory\n" if $deployment_mode eq 'devel';
            exit;
        }

        my $extra = $static->_load_json('.static.versions.extra.json')
          if -e '.static.versions.extra.json';
        $files = {%$files, %$extra} if $extra;

        #print Data::Dumper->Dump([\$files], [qw(files)]);

        for my $k (keys %$files) {
            my $version = $files->{$k} || 0;

            my $server       = DBI::hash("$k/$version", 1) + 0;
            my $server_short = ($server % 2) + 1;
            my $attr         = {
                server     => $server_short,
                server_num => $server % 100,
            };
            if ($k =~ m/(?<!-min)\.(css|js)/) {
                my $min = $k;
                $min =~ s/(\.[^\.]+)$/-min$1/;
                if (-f "$dir/$min") {
                    $attr->{min} = 1;
                }
            }

            $files->{$k} = [$version, $attr];
        }

        $files->{"..build.time"} = [$now, {}];

        nstore($files, $storable_file) or die "could not store $storable_file: $!";
        $static->_save_json($json_file, $files);
    }
}

sub _get_git_tree {
    my ($root, $dir) = @_;

    my $old_dir = getcwd();
    chdir("$root/$dir");

    my $command = "git ls-tree --abbrev -r HEAD $dir";
    my $git     = `$command`;
    my @submodules;

    my $files = {
        map {
            chomp;
            my ($type, $version, $file) = (split /\s/, $_)[1, 2, 3];
            push @submodules, $file if $type eq 'commit';
            ("/$file" => $version);
        } split /\n/,
        $git
    };

    my $git_status =
      `git status --porcelain=v2 --no-renames --ignore-submodules=none  --untracked-files=all $dir`;
    for (split /\n/, $git_status) {
        chomp;
        my ($file) = (split /\s/, $_)[-1];
        if (my $v = $files->{"/$file"}) {
            $files->{"/$file"} = "M-$v";
        }
    }

    for my $submodule (@submodules) {
        next if $submodule eq $root;    # prevent recursion
        my $sub = _get_git_tree($submodule, '.');
        $sub   = {map { ("/$submodule$_" => $sub->{$_}) } keys %$sub};
        $files = {%$files, %$sub};
    }

    chdir($old_dir);
    return $files;
}

1;
