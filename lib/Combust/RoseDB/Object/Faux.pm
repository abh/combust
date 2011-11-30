package Combust::RoseDB::Object::Faux;

require Carp;

sub save   { Carp::croak( "Cannot save a " . ref( $_[0] ) . " object" ); }
sub update { Carp::croak( "Cannot update a " . ref( $_[0] ) . " object" ); }
sub insert { Carp::croak( "Cannot insert a " . ref( $_[0] ) . " object" ); }

1;
