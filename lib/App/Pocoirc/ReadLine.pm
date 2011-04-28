package App::Pocoirc::ReadLine;

use strict;
use warnings FATAL => 'all';
use Carp;
use Data::Dump 'dump';
use POE;
use POE::Component::IRC::Plugin qw(PCI_EAT_NONE);
use POE::Wheel::ReadLine;
use POE::Wheel::ReadWrite;
use Symbol qw(gensym);

sub new {
    my ($package) = shift;
    croak "$package requires an even number of arguments" if @_ & 1;
    my $self = bless { @_ }, $package;

    POE::Session->create(
        object_states => [
            $self => [qw(
                _start
                got_user_input
                got_output
                restore_stdio
            )],
        ],
    );
    return $self;
}

sub PCI_register {
    my ($self, $irc, %args) = @_;

    if (!defined $self->{ui_irc}) {
        $self->{ui_irc} = $irc;
        $self->{console}->get("$args{network}> ");
    }

    $self->{ircs}{$args{network}} = $irc;
    $irc->plugin_register($self, 'SERVER', 'network');
    return 1;
}

sub PCI_unregister {
    my ($self, $irc, %args) = @_;
    $poe_kernel->call($self->{session_id}, 'restore_stdio');
    return 1;
}

sub _start {
    my ($kernel, $session, $self) = @_[KERNEL, SESSION, OBJECT];

    $self->{session_id} = $session->ID();
    $self->{console} = POE::Wheel::ReadLine->new(
        InputEvent => 'got_user_input',
        PutMode    => 'immediate',
        AppName    => 'pocoirc',
    );

    open my $orig_stderr, '>&', STDERR or die "Can't dup STDERR: $!";
    $self->{orig_stderr} = $orig_stderr;

    open my $orig_stdout, '>&', STDOUT or die "Can't dup STDOUT: $!";
    $self->{orig_stdout} = $orig_stdout;

    my ($read_stdout, $write_stdout) = (gensym(), gensym());
    pipe $read_stdout, $write_stdout;
    $self->{read_stdout} = $read_stdout;
    open STDOUT, '>&', $write_stdout or die "Can't pipe STDOUT: $!";

    my ($read_stderr, $write_stderr) = (gensym(), gensym());
    pipe $read_stderr, $write_stderr;
    $self->{read_stderr} = $read_stderr;
    open STDERR, '>&', $write_stderr or die "Can't pipe STDERR: $!";
    STDERR->autoflush(1);

    binmode $_, ':utf8' for (*STDOUT, *STDERR);

    $self->{stderr_reader} = POE::Wheel::ReadWrite->new(
        Handle     => $read_stderr,
        InputEvent => 'got_output',
    );
    $self->{stdout_reader} = POE::Wheel::ReadWrite->new(
        Handle     => $read_stdout,
        InputEvent => 'got_output',
    );

    $self->{console}->get();
    return;
}

sub got_output {
    my ($self, $line) = @_[OBJECT, ARG0];
    $self->{console}->put($line);
    return;
}

sub got_user_input {
    my ($self, $line, $ex) = @_[OBJECT, ARG0, ARG1];

    if (defined $ex && $ex eq 'interrupt') {
        $self->{Pocoirc}->shutdown('Exiting due to user interruption');
        return;
    }

    if (defined $line && length $line) {
        $self->{console}->add_history($line);

        if (my ($new_network) = $line =~ /^network\s*(.+)/) {
            my $found;
            while (my ($network, $irc) = each %{ $self->{ircs} }) {
                if ($network =~ /^\Q$new_network\E$/i) {
                    $self->{ui_irc} = $irc;
                    $self->{console}->get("$network> ");
                    $found = 1;
                    last;
                }
            }
            $self->_print_networks() if !$found;
        }
        elsif ($line =~ /^networks\s*$/) {
            $self->_print_networks();
        }
        elsif (my ($feature) = $line =~ /^(verbose|trace)\s*$/) {
            if ($self->{Pocoirc}->$feature()) {
                $self->{Pocoirc}->$feature(0);
                print "Disabled '$feature'\n";
            }
            else {
                $self->{Pocoirc}->$feature(1);
                print "Enabled '$feature'\n";
            }
        }
        elsif (my ($cmd, $args) = $line =~ m{^/([a-z_]+)\s*(.+)?}) {
            my @args = defined $args ? eval $args : ();
            $self->{ui_irc}->yield($cmd, @args);
        }
        elsif (my ($method, $params) = $line =~ m{^\.([a-z_]+)\s*(.+)?}) {
            my @params = defined $params ? eval $params : ();

            local ($@, $!);
            eval {
                print dump($self->{ui_irc}->$method(@params)), "\n";
            };
            if (my $err = $@) {
                chomp $err;
                warn $err, "\n";
            }
        }
        else {
            $self->_print_help();
        }
    }

    $self->{console}->get();
    return;
}

sub _print_help {
    my ($self) = @_;

    print <<'EOF';
Type "network foo" to switch networks, or "networks" for a list of networks.

Type ".foo 'bar'" to call the method "foo" with the argument 'bar" on the
IRC component. You must quote your arguments since they will be eval'd.

Type "/foo 'bar' 'baz'" to call the POE::Component::IRC command foo with the
arguments 'bar' and 'baz'. This is equivalent to: .yield 'foo' 'bar' 'baz'

Type "verbose" and "trace" to flip those features on/off.
EOF

    return;
}

sub _print_networks {
    my ($self) = @_;
    print "Available networks: ", join(', ', keys %{ $self->{ircs} }), "\n";
    return;
}

sub S_network {
    my ($self, $irc) = splice @_, 0, 2;
    my $network = ${ $_[0] };

    $self->{console}->get("$network> ");
    for my $net (keys %{ $self->{ircs} }) {
        if ($self->{ircs}{$net} == $irc) {
            delete $self->{ircs}{$net};
            $self->{ircs}{$network} = $irc;
        }
    }
    return PCI_EAT_NONE;
}

sub restore_stdio {
    my ($self) = $_[OBJECT];

    my $orig_stderr = delete $self->{orig_stderr};
    open STDERR, '>&', $orig_stderr or warn "Failed to restore STDERR: $!";
    STDERR->autoflush(1);

    my $orig_stdout = delete $self->{orig_stdout};
    open STDOUT, '>&', $orig_stdout or warn "Failed to restore STDERR: $!";

    binmode $_, ':encoding(utf8)', for (*STDERR, *STDOUT);

    delete $self->{console};
    delete $self->{stderr_reader};
    delete $self->{stdout_reader};
    return;
}

1;

=encoding utf8

=head1 NAME

App::Pocoirc::ReadLine - A PoCo-IRC plugin which provides a ReadLine UI

=head1 DESCRIPTION

This plugin is used internally by L<App::Pocoirc|App::Pocoirc>. No need for
you to use it.

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=cut
