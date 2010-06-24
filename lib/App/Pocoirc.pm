package App::Pocoirc;

use POE;

sub new {
    my ($package, %args) = @_;
    return bless \%args, $package;
}

sub run {
    my ($self) = @_;

    POE::Session->create(
        object_states => [
            $self => [qw(
                _start
            )],
        ],
    );

    $poe_kernel->run();
    return;
}

sub _start {
    my ($self) = $_[OBJECT];

    for my $network (@{ $self->{networks} }) {
        # foo
    }
}

1;

=head1 NAME

App::Pocoirc - Backend class for L<pocoirc>

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=head1 LICENSE AND COPYRIGHT

Copyright 2010 Hinrik E<Ouml>rn SigurE<eth>sson

This program is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
