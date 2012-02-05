package Combust::RoseDB::Manager;
use strict;
use base qw(Rose::DB::Object::Manager);

sub fetch {
  my $self = shift;
  my $obj = $self->object_class->new(@_);
  $obj->load(speculative => 1) ? $obj : undef;
}

sub fetch_or_create {
  my $self = shift;
  my $obj = $self->object_class->new(@_);
  $obj->load(speculative => 1);
  $obj;
}

sub create {
  shift->object_class->new(@_);
}

my %FAUX;

sub faux {
    my $self = shift;
    $FAUX{ ref $self } ||= do {
        my $base_class   = $self->object_class;
        my $faux_manager = ref($self) . "::Faux";
        my $faux_class   = $base_class . "::Faux";
        require Combust::RoseDB::Object::Faux;
        no strict 'refs';
        @{ $faux_class . "::ISA" } = ( 'Combust::RoseDB::Object::Faux', $base_class );
        @{ $faux_manager . "::ISA" } = ( ref $self );
        my $obj = bless \( my $tmp ), $faux_manager;
        *{ $faux_manager . "::faux" }         = sub {$obj};
        *{ $faux_manager . "::object_class" } = sub {$faux_class};
        $obj;
    };
}

1;
