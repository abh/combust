package Combust::Redirect;
use Moose::Role;
use Combust::Control::Redirect;

after 'BUILD' => sub {
    my ($self, $params) = @_;
    my $rewriter = Combust::Control::Redirect->new(request => undef);
    $self->rewriter($rewriter);
};

1;
