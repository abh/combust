package Combust::Control::Bitcard::DBIC;
use strict;
use base qw(Combust::Control::Bitcard);

sub _setup_user {
    my ($self, $bc_user) = @_;
    my $user;

    my $object_class = $self->bc_user_class->result_source;
    if (my $info = $object_class->columns_info(['username'])) {
        # TODO: check that this column has a unique key, too.
        $user = $self->bc_user_class->find( { username => $bc_user->{username} });
    }

    unless ($user) {
        $user = $self->bc_user_class->find_or_new({ bitcard_id => $bc_user->{id} });
    }

    for my $m (qw(username email name)) {
        next unless $user->can($m);
        $user->$m($bc_user->{$m});
    }

    $user->bitcard_id($bc_user->{id});
    $user->update_or_insert;
    return $user;
}

1;
