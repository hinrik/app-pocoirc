package App::Pocoirc;

use strict;
use warnings;
use IO::Handle;
use POE;
use POSIX 'strftime';

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

    # misc things
    $self->_global_setup();

    # compilation and config validation
    $self->_require_plugin($_) for @{ $self->{cfg}{global_plugins} || [] };
    for my $opts (@{ $self->{cfg}{networks} }) {
        $self->_require_plugin($_) for @{ $opts->{local_plugins} || [] };

        die "Network name missing\n" if !defined $opts->{name};

        if (!defined $opts->{server}) {
            die "Server for network '$opts->{name}' not specified\n";
        }

        while (my ($opt, $value) = each %{ $self->{cfg} }) {
            next if $opt =~ /^(?:networks|global_plugins|local_plugins)$/;
            $opts->{$opt} = $value if !defined $opts->{$opt};
        }

        $opts->{class} = 'POE::Component::IRC::State' if !defined $opts->{class};
        eval "require $opts->{class}";
        chomp $@;
        die "Can't load class $opts->{class}: $@\n" if $@;
    }

    if ($self->{check_cfg}) {
        print "Config file is valid all modules could be compiled.\n";
        return;
    }

    if ($self->{daemonize}) {
        require Proc::Daemon;
        eval { Proc::Daemon::Init->() };
        chomp $@;
        die "Can't daemonize: $@\n" if $@;
    }

    # all exceptions will now be colored & timestamped status messages
    $kernel->sig(DIE => '_exception');

    # this can not be done earlier due to a bug in Perl 5.12 which causes
    # the compilation of Net::DNS (used by POE::Component::IRC) to clear
    # the signal handler
    $kernel->sig(INT => '_exit');

    $self->_status("Started");

    # construct global plugins
    $self->_status("Constructing global plugins");
    $self->{global_plugs} = $self->_create_plugins(delete $self->{cfg}{global_plugins});

    # construct IRC components
    for my $opts (@{ $self->{cfg}{networks} }) {
        my $network = delete $opts->{name};
        my $class = delete $opts->{class};
        
        # construct network-specific plugins
        $self->_status('Constructing local plugins', $network);
        $self->{local_plugs}{$network} = $self->_create_plugins(delete $opts->{local_plugins});

        $self->_status('Spawning IRC component', $network);
        my $irc = $class->spawn(%$opts);
        push @{ $self->{ircs} }, [$network, $irc];
    }


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

# a few things to take care of at start up
sub _global_setup {
    my ($self) = @_;

    if (my $log = delete $self->{cfg}{log_file}) {
        open my $fh, '>>', $log or die "Can't open $log: $!\n";
        close $fh;
        $self->{log_file} = $log;
    }

    if (!$self->{no_color}) {
        require Term::ANSIColor;
        Term::ANSIColor->import();
    }

    if (defined $self->{cfg}{lib} && @{ $self->{cfg}{lib} }) {
        my $lib = delete $self->{cfg}{lib};
        unshift @INC, @$lib;
    }

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
    return if !$self->{verbose};
    my $irc = $_[SENDER]->get_heap();
    $self->_status("->$raw", $irc);
    return;
}

sub _status {
    my ($self, $message, $context, $error) = @_;

    my $stamp = strftime('%Y-%m-%d %H:%M:%S', localtime);
    my $irc; eval { $irc = $context->isa('POE::Component::IRC') };
    $context = $self->_irc_to_network($context) if $irc;
    $context = defined $context ? " [$context]" : '';
    
    $message = "$stamp$context $message";

    if (!$self->{daemonize}) {
        if ($error) {
            print colored($message, 'red'), "\n";
        }
        else {
            print colored($message, 'green'), "\n";
        }
    }

    if (defined $self->{log_file}) {
        my $fh;
        if (!open($fh, '>>:encoding(utf8)', $self->{log_file}) && !$self->{daemonize}) {
            warn "Can't open $self->{log_file}: $!\n";
        }

        $fh->autoflush(1);
        print $fh $message, "\n";
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

# find out the canonical class name for the plugin and require() it
sub _require_plugin {
    my ($self, $plug_spec) = @_;

    my ($class, $args) = @$plug_spec;
    $args = {} if !defined $args;

    my $fullclass = "POE::Component::IRC::Plugin::$class";
    my $canonclass = $fullclass;
    my $error;
    eval "require $fullclass";
    if ($@) {
        $error .= $@;
        eval "require $class";
        if ($@) {
            chomp $@;
            $error .= $@;
            die "Failed to load plugin $class or $fullclass: $error\n";
        }
        $canonclass = $class;
    }

    $plug_spec->[1] = $args;
    $plug_spec->[2] = $canonclass;
    return;
}

sub _create_plugins {
    my ($self, $plugins) = @_;

    my @return;
    for my $plug_spec (@$plugins) {
        my ($class, $args, $canonclass) = @$plug_spec;
        my $obj = $canonclass->new(%$args);
        push @return, [$class, $obj];
    }

    return \@return;
}

sub _exception {
    my ($kernel, $self, $ex) = @_[KERNEL, OBJECT, ARG1];
    chomp $ex->{error_str};

    my @errors = (
        "Event $ex->{event} in session ".$ex->{dest_session}->ID." raised exception:",
        "    $ex->{error_str}",
    );

    $self->_status($_, undef, 1) for @errors;
    $self->_shutdown('Caught exception');
    $kernel->sig_handled();
    return;
}

sub _exit {
    my ($kernel, $self) = @_[KERNEL, OBJECT];

    $self->_status('Caught interrupt signal, exiting...');
    $self->_shutdown('Caught interrupt');
    $kernel->sig_handled();
    return;
}

sub _shutdown {
    my ($self, $reason) = @_;

    if (!$self->{shutdown}) {
        for my $irc (@{ $self->{ircs} }) {
            my ($network, $obj) = @$irc;
            $obj->connected
                ? $obj->yield(quit => $reason)
                : $obj->yield('shutdown');
        }
        $self->{shutdown} = 1;
    }

    return;
}

1;

=encoding utf8

=head1 NAME

App::Pocoirc - The guts of L<pocoirc>

=head1 DESCRIPTION

This distribution provides a generic way to launch IRC clients which use
L<POE::Component::IRC|POE::Component::IRC>. The main features are:

=over 4

=item * Prints useful status information (to your terminal and/or a log file)

=item * Will daemonize if you so wish

=item * Supports a configuration file

=item * Offers a user friendly way to pass arguments to POE::Component::IRC

=item * Supports multiple IRC components and lets you specify which plugins
to load locally (one object per component) or globally (single object)

=back

=head1 CONFIGURATION

 nick: foobar1234
 username: foobar

 global_plugins:
   - [CTCP]

 local_plugins:
   - [BotTraffic]

 networks:
   - name:   freenode
     server: irc.freenode.net
     local_plugins:
       - [AutoJoin, { Channels: ['#foodsfdsf'] } ]

   - name:   magnet
     server: irc.perl.org
     nick:   hlagherf32fr

The configuration file is in L<YAML|YAML> or L<JSON|JSON> format. It consists
of a hash containing C<global_plugins>, C<local_plugins>, C<networks>, C<lib>,
C<log_file>, and default parameters to
L<POE::Component::IRC|POE::Component::IRC/spawn>. Only C<networks> is
required.

C<lib> is an array of directories containing Perl modules (e.g. plugins).
Just like Perl's I<-I>.

C<log_file> is the path to a log to which status messages will be written.

=head2 Networks

The C<network> option should be an array of network hashes. A network hash
consists of C<name>, C<local_plugins>, and parameters to POE::Component::IRC.
Only C<name> (and C<server> if not defined the top level) is required.
The POE::Component::IRC parameters specified in this hash will override the
ones specified at the top level.

=head2 Plugins

The C<global_plugins> and C<local_plugins> options should consist of an array
containing the short plugin class name (e.g. 'AutoJoin') and optionally a hash
of arguments to that plugin. App::Pocoirc will first try to load
POE::Component::IRC::Plugin::I<your_plugin> before trying to load
I<your_plugin>.

The plugins in C<global_plugins> will be instantiated once and then added to
all IRC components. B<Note:> not all plugins are designed to be used with
multiple IRC components simultaneously.

If you specify C<local_plugins> at the top level, it will serve as a default
list of local plugins, which can be overridden in a network hash.

=head1 OUTPUT

Here is some example output from the program:

 $ pocoirc -c example/config.yml
 2010-06-25 20:21:37 Started
 2010-06-25 20:21:37 Constructing global plugins
 2010-06-25 20:21:37 [freenode] Constructing local plugins
 2010-06-25 20:21:37 [freenode] Spawning IRC component
 2010-06-25 20:21:37 [magnet] Constructing local plugins
 2010-06-25 20:21:37 [magnet] Spawning IRC component
 2010-06-25 20:21:37 [freenode] Registering plugins
 2010-06-25 20:21:37 [freenode] Connecting to IRC
 2010-06-25 20:21:37 [magnet] Registering plugins
 2010-06-25 20:21:37 [magnet] Connecting to IRC
 2010-06-25 20:21:37 [freenode] Added plugin Whois3
 2010-06-25 20:21:37 [freenode] Added plugin ISupport3
 2010-06-25 20:21:37 [freenode] Added plugin DCC3
 2010-06-25 20:21:37 [magnet] Added plugin Whois6
 2010-06-25 20:21:37 [magnet] Added plugin ISupport6
 2010-06-25 20:21:37 [magnet] Added plugin DCC6
 2010-06-25 20:21:37 [freenode] Added plugin CTCP2
 2010-06-25 20:21:37 [freenode] Added plugin AutoJoin2
 2010-06-25 20:21:37 [magnet] Added plugin CTCP2
 2010-06-25 20:21:37 [magnet] Added plugin BotTraffic2
 2010-06-25 20:21:38 [freenode] Connected to server 213.92.8.4
 2010-06-25 20:21:38 [freenode] Server notice: *** Looking up your hostname...
 2010-06-25 20:21:38 [freenode] Server notice: *** Checking Ident
 2010-06-25 20:21:38 [freenode] Server notice: *** Found your hostname
 2010-06-25 20:21:38 [magnet] Connected to server 209.221.142.115
 2010-06-25 20:21:38 [magnet] Server notice: *** Looking up your hostname...
 2010-06-25 20:21:38 [magnet] Server notice: *** Checking Ident
 2010-06-25 20:21:39 [magnet] Server notice: *** Found your hostname
 2010-06-25 20:21:49 [freenode] Server notice: *** No Ident response
 2010-06-25 20:21:49 [freenode] Logged in to server calvino.freenode.net with nick foobar1234
 2010-06-25 20:21:49 [magnet] Server notice: *** No Ident response
 2010-06-25 20:21:49 [magnet] Logged in to server magnet.llarian.net with nick hlagherf32fr
 2010-06-25 20:21:51 [freenode] Joined channel #foodsfdsf
 2010-06-25 20:21:55 Caught interrupt signal, exiting...
 2010-06-25 20:21:55 [freenode] Quit from IRC (Client Quit)
 2010-06-25 20:21:55 [freenode] Error from IRC server: Closing Link: 194-144-99-91.du.xdsl.is (Client Quit)
 2010-06-25 20:21:55 [freenode] Disconnected from server 213.92.8.4
 2010-06-25 20:21:55 [freenode] Shutting down
 2010-06-25 20:21:55 [freenode] Deleted plugin DCC3
 2010-06-25 20:21:55 [freenode] Deleted plugin AutoJoin2
 2010-06-25 20:21:55 [freenode] Deleted plugin CTCP2
 2010-06-25 20:21:55 [freenode] Deleted plugin Whois3
 2010-06-25 20:21:55 [freenode] Deleted plugin ISupport3
 2010-06-25 20:21:55 [magnet] Error from IRC server: Closing Link: 194-144-99-91.du.xdsl.is ()
 2010-06-25 20:21:55 [magnet] Disconnected from server 209.221.142.115
 2010-06-25 20:21:55 [magnet] Shutting down
 2010-06-25 20:21:55 [magnet] Deleted plugin BotTraffic2
 2010-06-25 20:21:55 [magnet] Deleted plugin DCC6
 2010-06-25 20:21:55 [magnet] Deleted plugin ISupport6
 2010-06-25 20:21:55 [magnet] Deleted plugin CTCP2
 2010-06-25 20:21:55 [magnet] Deleted plugin Whois6

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=head1 LICENSE AND COPYRIGHT

Copyright 2010 Hinrik E<Ouml>rn SigurE<eth>sson

This program is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
