package App::Pocoirc;

use strict;
use warnings;
use POE;
use POSIX 'strftime';

sub new {
    my ($package, %args) = @_;
    return bless \%args, $package;
}

sub run {
    my ($self) = @_;

    if (defined $self->{lib} && @{ $self->{lib} }) {
        unshift @INC, @{ $self->{lib} };
    }

    if (defined $self->{log_file}) {
        open my $fh, '>>', $self->{log_file} or die "Can't open $self->{log_file}: $!\n";
        close $fh;
    }

    # construct global plugins
    $self->_status("Constructing global plugins");
    $self->{global_plugs} = $self->_create_plugins(delete $self->{cfg}{global_plugins});

    if ($self->{daemonize}) {
        require Proc::Daemon;
        eval { Proc::Daemon::Init->() };
        chomp $@;
        die "Can't daemonize: $@\n" if $@;
    }

    POE::Session->create(
        object_states => [
            $self => [qw(
                _start
                _exception
                _exit
                irc_connected
                irc_disconnected
                irc_snotice
                irc_notice
                irc_001
                irc_quit
                irc_nick
                irc_join
                irc_part
                irc_kick
                irc_error
                irc_socketerr
                irc_shutdown
                irc_socks_failed
                irc_socks_rejected
                irc_plugin_add
                irc_plugin_del
                irc_plugin_error
                irc_raw
            )],
        ],
    );

    $poe_kernel->run();
    return;
}

sub _start {
    my ($kernel, $session, $self) = @_[KERNEL, SESSION, OBJECT];

    $kernel->sig(DIE => '_exception');
    $kernel->sig(INT => '_exit');
    
    my @ircs;

    # construct IRC components
    for my $opts (@{ $self->{cfg}{networks} }) {
        die "Network name missing\n" if !defined $opts->{name};
        my $network = delete $opts->{name};
        my $class = delete $opts->{class};
        
        if (!defined $opts->{server}) {
            die "Server for network '$network' not specified\n";
        }

        while (my ($opt, $value) = each %{ $self->{cfg} }) {
            $opts->{$opt} = $value if !defined $opts->{$opt};
        }
        
        # construct network-specific plugins
        $self->_status('Constructing local plugins', $network);
        $self->{local_plugs}{$network} = $self->_create_plugins(delete $opts->{local_plugins});

        $class = 'POE::Component::IRC::State' if !defined $class;
        eval "require $class";
        chomp $@;
        die "Can't load class $class: $@" if $@;

        $self->_status('Spawning IRC component', $network);
        my $irc = $class->spawn(%$opts);

        push @ircs, [$network, $irc];
    }

    $self->{ircs} = \@ircs;

    for my $entry (@{ $self->{ircs} }) {
        my ($network, $irc) = @$entry;
        
        $irc->raw_events(1) if $self->{verbose};
        
        # add the plugins
        $self->_status('Registering plugins', $network);

        my @plugins = (
            @{ $self->{global_plugs} },
            @{ $self->{local_plugs}{$network} }
        );

        for my $plugin (@plugins) {
            my ($class, $object) = @$plugin;
            my $name = $class.$session->ID();
            $irc->plugin_add($name, $object);
        }

        $self->_status('Connecting to IRC', $network);
        $irc->yield('connect');
    }

    delete $self->{global_plugs};
    delete $self->{local_plugs};

    return;
}

sub irc_connected {
    my ($self, $address) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Connected to server $address", $irc);
    return;
}

sub irc_disconnected {
    my ($self, $server) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Disconnected from server $server", $irc);

    $irc->yield('shutdown') if $self->{shutdown};
    return;
}

sub irc_snotice {
    my ($self, $notice) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Server notice: $notice", $irc);
    return;
}

sub irc_notice {
    my ($self, $sender, $notice) = @_[OBJECT, ARG0, ARG2];
    my $irc = $_[SENDER]->get_heap();

    if (defined $irc->server_name() && $sender ne $irc->server_name()) {
        return;
    }
    #return if $sender ne $irc->server_name();

    $self->_status("Server notice: $notice", $irc);
    return;
}

sub irc_001 {
    my ($self, $server) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    my $nick = $irc->nick_name();
    $self->_status("Logged in to server $server with nick $nick", $irc);
    return;
}

sub irc_nick {
    my ($self, $user, $newnick) = @_[OBJECT, ARG0, ARG1];
    my $oldnick = (split /!/, $user)[0];
    my $irc = $_[SENDER]->get_heap();
    return if $newnick ne $irc->nick_name();
    $self->_status("Nickname changed from $oldnick to $newnick", $irc);
    return;
}

sub irc_join {
    my ($self, $user, $chan) = @_[OBJECT, ARG0, ARG1];
    my $nick = (split /!/, $user)[0];
    my $irc = $_[SENDER]->get_heap();
    return if $nick ne $irc->nick_name();
    $self->_status("Joined channel $chan", $irc);
    return;
}

sub irc_part {
    my ($self, $user, $chan, $reason) = @_[OBJECT, ARG0..ARG2];
    my $nick = (split /!/, $user)[0];
    my $irc = $_[SENDER]->get_heap();
    return if $nick ne $irc->nick_name();
    my $msg = "Parted channel $chan";
    $msg .= " ($reason)" if defined $reason;
    $self->_status($msg, $irc);
    return;
}

sub irc_kick {
    my ($self, $kicker, $chan, $victim, $reason) = @_[OBJECT, ARG0..ARG3];
    $kicker = (split /!/, $kicker)[0];
    my $irc = $_[SENDER]->get_heap();
    return if $victim ne $irc->nick_name();
    my $msg = "Kicked from $chan by $kicker";
    $msg .= " ($reason)" if length $reason;
    $self->_status($msg, $irc);
    return;
}

sub irc_error {
    my ($self, $error) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Error from IRC server: $error", $irc);
    return;
}

sub irc_quit {
    my ($self, $user, $reason) = @_[OBJECT, ARG0, ARG1];
    my $irc = $_[SENDER]->get_heap();

    my $nick = (split /!/, $user)[0];
    return if $nick ne $irc->nick_name();
    my $msg = 'Quit from IRC';
    $msg .= " ($reason)" if length $reason;
    $self->_status($msg, $irc);
    return;
}

sub irc_shutdown {
    my ($self) = $_[OBJECT];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Shutting down", $irc);
    return;
}

sub irc_socketerr {
    my ($self, $reason) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Failed to connect to server: $reason", $irc);
    return;
}

sub irc_socks_failed {
    my ($self, $reason) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Failed to connect to SOCKS server: $reason", $irc);
    return;
}

sub irc_socks_rejected {
    my ($self, $code) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Connection rejected by SOCKS server (code $code)", $irc);
    return;
}

sub irc_plugin_add {
    my ($self, $alias) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Added plugin $alias", $irc);
    return;
}

sub irc_plugin_del {
    my ($self, $alias) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Deleted plugin $alias", $irc);
    return;
}

sub irc_plugin_error {
    my ($self, $error) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status($error, $irc);
    return;
}

sub irc_raw {
    my ($self, $raw) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("->$raw", $irc);
    return;
}

sub _status {
    my ($self, $message, $context) = @_;

    my $stamp = strftime('%Y-%m-%d %H:%M:%S', localtime);
    $context = 'GLOBAL' if !defined $context;
    my $irc; eval { $irc = $context->isa('POE::Component::IRC') };
    $context = $self->_irc_to_network($context) if $irc;
    
    $message = "$stamp [$context] $message\n";
    print $message if !$self->{daemonize};

    if ($self->{log_file}) {
        open my $fh, '>>', $self->{log_file} or warn "Can't open $self->{log_file}: $!\n";
        print $fh "$message\n";
        close $fh;
    }

    return;
}

sub _irc_to_network {
    my ($self, $irc) = @_;

    for my $entry (@{ $self->{ircs} }) {
        my ($network, $object) = @$entry;
        return $network if $irc == $object;
    }

    return;
}

sub _create_plugins {
    my ($self, $plugins) = @_;

    my @return;
    for my $plugin (@$plugins) {
        my ($class, $args) = @$plugin;
        $args = {} if !defined $args;

        my $fullclass = "POE::Component::IRC::Plugin::$class";
        my $canonclass = $fullclass;
        eval "require $fullclass";
        if ($@) {
            eval "require $class";
            die "Failed to load plugin $class or $fullclass\n" if $@;
            $canonclass = $class;
        }

        my $obj = $canonclass->new(%$args);
        push @return, [$class, $obj];
    }

    return \@return;
}

sub _exception {
    my ($kernel, $self, $ex) = @_[KERNEL, OBJECT, ARG1];
    chomp $ex->{error_str};
    warn "Event $ex->{event} in session "
        .$ex->{dest_session}->ID." raised exception:\n  $ex->{error_str}\n";
    $kernel->sig_handled();
    return;
}

sub _exit {
    my ($kernel, $self) = @_[KERNEL, OBJECT];

    $self->_status('Caught interrupt signal, exiting...');
    for my $irc (@{ $self->{ircs} }) {
        my ($network, $obj) = @$irc;
        $obj->connected
            ? $obj->yield(quit => 'Caught interrupt')
            : $obj->shutdown();
    }
    $self->{shutdown} = 1;

    $kernel->sig_handled();
    return;
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
