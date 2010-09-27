package App::Pocoirc;

use strict;
use warnings FATAL => 'all';

# we want instant child process reaping
sub POE::Kernel::USE_SIGCHLD () { return 1 }

use App::Pocoirc::Status;
use IO::Handle;
use POE;
use POE::Component::IRC::Common qw(irc_to_utf8);
use POE::Component::Client::DNS;
use POSIX 'strftime';
use Module::Pluggable
    sub_name    => '_available_plugins',
    search_path => 'POE::Component::IRC::Plugin';

sub new {
    my ($package, %args) = @_;
    return bless \%args, $package;
}

sub run {
    my ($self) = @_;

    if ($self->{list_plugins}) {
        for my $plugin ($self->_available_plugins()) {
            $plugin =~ s/^POE::Component::IRC::Plugin:://;
            print $plugin, "\n";
        }
        return;
    }

    $self->_setup();

    if ($self->{check_cfg}) {
        print "The configuration is valid and all modules could be compiled.\n";
        return;
    }

    if ($self->{daemonize}) {
        require Proc::Daemon;
        eval { Proc::Daemon::Init->() };
        chomp $@;
        die "Can't daemonize: $@\n" if $@;
    }

    if (defined $self->{cfg}{pid_file}) {
        my $file = $self->{cfg}{pid_file};
        die "Pid file already exists. Pocoirc already running?\n" if -e $file;
        open my $fh, '>', $file or die "Can't create pid file $file: $!\n";
        print $fh "$$\n";
        close $fh;
    }

    POE::Session->create(
        object_states => [
            $self => [qw(
                _start
                sig_die
                sig_int
                sig_term
                quit_timeout
                irc_plugin_add
                irc_plugin_del
                irc_plugin_error
                irc_disconnected
                irc_433
            )],
        ],
    );

    $poe_kernel->run();
    unlink $self->{cfg}{pid_file} if defined $self->{cfg}{pid_file};
    return;
}

# compilation and config validation
sub _setup {
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

    for my $plug_spec (@{ $self->{cfg}{global_plugins} || [] }) {
        $self->_require_plugin($plug_spec);
    }

    for my $opts (@{ $self->{cfg}{networks} }) {
        die "Network name missing\n" if !defined $opts->{name};

        while (my ($opt, $value) = each %{ $self->{cfg} }) {
            next if $opt =~ /^(?:networks|global_plugins|local_plugins)$/;
            $opts->{$opt} = $value if !defined $opts->{$opt};
        }

        for my $plug_spec (@{ $opts->{local_plugins} || [] }) {
            $self->_require_plugin($plug_spec);
        }

        if (!defined $opts->{server}) {
            die "Server for network '$opts->{name}' not specified\n";
        }

        $opts->{class} = 'POE::Component::IRC::State' if !defined $opts->{class};
        eval "require $opts->{class}";
        chomp $@;
        die "Can't load class $opts->{class}: $@\n" if $@;
    }

    return;
}

# create plugins, spawn components, and connect to IRC
sub _start {
    my ($kernel, $session, $self) = @_[KERNEL, SESSION, OBJECT];

    $kernel->sig(DIE => 'sig_die');
    $kernel->sig(INT => 'sig_int');
    $kernel->sig(TERM => 'sig_term');
    $self->_status("Started (pid $$)");

    # create the shared DNS resolver
    $self->{resolver} = POE::Component::Client::DNS->spawn();

    # construct global plugins
    $self->_status("Constructing global plugins");
    $self->{global_plugs} = $self->_create_plugins(delete $self->{cfg}{global_plugins});

    my $status_plugin = App::Pocoirc::Status->new(
        Pocoirc => $self,
        Trace   => $self->{trace},
        Verbose => $self->{verbose},
    );

    # construct IRC components
    for my $opts (@{ $self->{cfg}{networks} }) {
        my $network = delete $opts->{name};
        my $class = delete $opts->{class};

        # construct network-specific plugins
        $self->_status('Constructing local plugins', $network);
        $self->{local_plugs}{$network} = $self->_create_plugins(delete $opts->{local_plugins});

        $self->_status('Spawning IRC component', $network);
        my $irc = $class->spawn(
            %$opts,
            Resolver => $self->{resolver},
        );
        push @{ $self->{ircs} }, [$network, $irc];
    }

    for my $entry (@{ $self->{ircs} }) {
        my ($network, $irc) = @$entry;
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

        # add our status plugin and bump it to the front of the pipeline
        $irc->plugin_add('PocoircStatus'.$session->ID(), $status_plugin);
        my $idx = $irc->pipeline->get_index($status_plugin);
        $irc->pipeline->bump_up($status_plugin, $idx);
    }

    for my $entry (@{ $self->{ircs} }) {
        my ($network, $irc) = @$entry;
        $self->_status('Connecting to IRC', $network);
        $irc->yield('connect');
    }

    delete $self->{global_plugs};
    delete $self->{local_plugs};

    return;
}

# let's log this if it's preventing us from logging in
sub irc_433 {
    my $self = $_[OBJECT];
    my $irc = $_[SENDER]->get_heap();
    my $reason = irc_to_utf8($_[ARG2]->[1]);
    return if $irc->logged_in();
    my $nick = $irc->nick_name();
    $self->_status("Unable to log in: $reason", $irc);
    return;
}

# we handle plugin status messages here because the status plugin won't
# see these for previously added plugins or plugin_del for itself, etc
sub irc_plugin_add {
    my ($self, $alias) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Event S_plugin_add", $irc, 'debug') if $self->{trace};
    $self->_status("Added plugin $alias", $irc);
    return;
}

sub irc_plugin_del {
    my ($self, $alias) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Event S_plugin_del", $irc, 'debug') if $self->{trace};
    $self->_status("Deleted plugin $alias", $irc);
    return;
}

sub irc_plugin_error {
    my ($self, $error) = @_[OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();
    $self->_status("Event S_plugin_error", $irc, 'debug') if $self->{trace};
    $self->_status($error, $irc, 'error');
    return;
}

sub irc_disconnected {
    my ($kernel, $self, $server) = @_[KERNEL, OBJECT, ARG0];
    my $irc = $_[SENDER]->get_heap();

    $irc->yield('shutdown') if $self->{shutdown};
    my $network = $self->_irc_to_network($irc);
    delete $self->{waiting}{$network};
    $kernel->delay('quit_timeout') if !keys %{ $self->{waiting} };
    return;
}

sub _status {
    my ($self, $message, $context, $type) = @_;

    my $stamp = strftime('%Y-%m-%d %H:%M:%S', localtime);
    my $irc; eval { $irc = $context->isa('POE::Component::IRC') };
    $context = $self->_irc_to_network($context) if $irc;
    $context = defined $context ? " [$context]\t" : ' ';

    if (defined $type && $type eq 'error') {
        $message = "!!! $message";
    }
    elsif (defined $type && $type eq 'debug') {
        $message = ">>> $message";
    }

    my $log_line = "$stamp$context$message";
    my $term_line = $log_line;

    if (!$self->{no_color}) {
        if (defined $type && $type eq 'error') {
            $term_line = colored($term_line, 'red');
        }
        elsif (defined $type && $type eq 'debug') {
            $term_line = colored($term_line, 'yellow');
        }
        else {
            $term_line = colored($term_line, 'green');
        }
    }

    print $term_line, "\n" if !$self->{daemonize};

    if (defined $self->{log_file}) {
        my $fh;
        if (!open($fh, '>>:encoding(utf8)', $self->{log_file}) && !$self->{daemonize}) {
            warn "Can't open $self->{log_file}: $!\n";
        }

        $fh->autoflush(1);
        print $fh $log_line, "\n";
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

    return if defined $plug_spec->[2];
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

sub sig_die {
    my ($kernel, $self, $ex) = @_[KERNEL, OBJECT, ARG1];
    chomp $ex->{error_str};

    my @errors = (
        "Event $ex->{event} in session ".$ex->{dest_session}->ID." raised exception:",
        "    $ex->{error_str}",
    );

    $self->_status($_, undef, 'error') for @errors;

    if (!$self->{shutdown}) {
        $self->_shutdown('Exiting due to an exception');
    }

    $kernel->sig_handled();
    return;
}

sub sig_int {
    my ($kernel, $self) = @_[KERNEL, OBJECT];

    if (!$self->{shutdown}) {
        $self->_status('Exiting due to SIGINT');
        $self->_shutdown('Exiting due to SIGINT');
    }
    $kernel->sig_handled();
    return;
}

sub sig_term {
    my ($kernel, $self) = @_[KERNEL, OBJECT];

    if (!$self->{shutdown}) {
        $self->_status('Exiting due to SIGTERM');
        $self->_shutdown('Exiting due to SIGTERM');
    }

    $kernel->sig_handled();
    return;
}

sub _shutdown {
    my ($self, $reason) = @_;

    for my $irc (@{ $self->{ircs} }) {
        my ($network, $obj) = @$irc;

        if ($obj->logged_in()) {
            if (!keys %{ $self->{waiting} }) {
                $self->_status('Waiting up to 5 seconds for IRC server(s) to disconnect us');
                $poe_kernel->delay('quit_timeout', 5);
            }
            $self->{waiting}{$network} = $obj;
            $obj->yield(quit => $reason);
        }
        elsif ($obj->connected()) {
            $obj->disconnect();
        }
        else {
            $obj->yield('shutdown');
        }
    }

    $self->{resolver}->shutdown();
    $self->{shutdown} = 1;

    return;
}

sub quit_timeout {
    my ($self) = $_[OBJECT];
    $_->yield('shutdown') for values %{ $self->{waiting} };
    return;
}

1;

=encoding utf8

=head1 NAME

App::Pocoirc - A command line tool for launching POE::Component::IRC clients

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

The C<networks> option should be an array of network hashes. A network hash
consists of C<name>, C<local_plugins>, and parameters to POE::Component::IRC.
Only C<name> (and C<server> if not defined at the top level) is required.
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

 $ pocoirc -f example/config.yml
 2010-09-26 02:49:41 Started (pid 27534)
 2010-09-26 02:49:41 Constructing global plugins
 2010-09-26 02:49:41 [freenode]  Constructing local plugins
 2010-09-26 02:49:41 [freenode]  Spawning IRC component
 2010-09-26 02:49:41 [magnet]    Constructing local plugins
 2010-09-26 02:49:41 [magnet]    Spawning IRC component
 2010-09-26 02:49:41 [freenode]  Registering plugins
 2010-09-26 02:49:41 [magnet]    Registering plugins
 2010-09-26 02:49:41 [freenode]  Connecting to IRC
 2010-09-26 02:49:41 [magnet]    Connecting to IRC
 2010-09-26 02:49:41 [freenode]  Added plugin Whois3
 2010-09-26 02:49:41 [freenode]  Added plugin ISupport3
 2010-09-26 02:49:41 [freenode]  Added plugin DCC3
 2010-09-26 02:49:41 [magnet]    Added plugin Whois6
 2010-09-26 02:49:41 [magnet]    Added plugin ISupport6
 2010-09-26 02:49:41 [magnet]    Added plugin DCC6
 2010-09-26 02:49:41 [freenode]  Added plugin CTCP2
 2010-09-26 02:49:41 [freenode]  Added plugin AutoJoin2
 2010-09-26 02:49:41 [freenode]  Added plugin PocoircStatus2
 2010-09-26 02:49:41 [magnet]    Added plugin CTCP2
 2010-09-26 02:49:41 [magnet]    Added plugin PocoircStatus2
 2010-09-26 02:49:41 [magnet]    Connected to server 217.168.153.160
 2010-09-26 02:49:41 [freenode]  Connected to server 130.237.188.200
 2010-09-26 02:49:41 [magnet]    Server notice: *** Looking up your hostname...
 2010-09-26 02:49:41 [magnet]    Server notice: *** Checking Ident
 2010-09-26 02:49:41 [freenode]  Server notice: *** Looking up your hostname...
 2010-09-26 02:49:41 [freenode]  Server notice: *** Checking Ident
 2010-09-26 02:49:41 [freenode]  Server notice: *** Found your hostname
 2010-09-26 02:49:41 [magnet]    Server notice: *** Found your hostname
 2010-09-26 02:49:51 [magnet]    Server notice: *** No Ident response
 2010-09-26 02:49:51 [magnet]    Logged in to server electret.shadowcat.co.uk with nick hlagherf32fr
 2010-09-26 02:49:55 [freenode]  Server notice: *** No Ident response
 2010-09-26 02:49:55 [freenode]  Logged in to server lindbohm.freenode.net with nick foobar1234
 2010-09-26 02:50:00 [freenode]  Joined channel #foodsfdsf
 2010-09-26 02:50:15 Exiting due to SIGINT
 2010-09-26 02:50:15 Waiting up to 5 seconds for IRC server(s) to disconnect us
 2010-09-26 02:50:15 [magnet]    Error from IRC server: Closing Link: 212-30-192-157.static.simnet.is ()
 2010-09-26 02:50:15 [magnet]    Disconnected from server 217.168.153.160
 2010-09-26 02:50:15 [magnet]    Shutting down
 2010-09-26 02:50:15 [freenode]  Quit from IRC (Client Quit)
 2010-09-26 02:50:15 [magnet]    Deleted plugin DCC6
 2010-09-26 02:50:15 [magnet]    Deleted plugin ISupport6
 2010-09-26 02:50:15 [magnet]    Deleted plugin CTCP2
 2010-09-26 02:50:15 [magnet]    Deleted plugin Whois6
 2010-09-26 02:50:15 [magnet]    Deleted plugin PocoircStatus2
 2010-09-26 02:50:15 [freenode]  Error from IRC server: Closing Link: 212-30-192-157.static.simnet.is (Client Quit)
 2010-09-26 02:50:15 [freenode]  Disconnected from server 130.237.188.200
 2010-09-26 02:50:15 [freenode]  Shutting down
 2010-09-26 02:50:15 [freenode]  Deleted plugin DCC3
 2010-09-26 02:50:15 [freenode]  Deleted plugin AutoJoin2
 2010-09-26 02:50:15 [freenode]  Deleted plugin CTCP2
 2010-09-26 02:50:15 [freenode]  Deleted plugin Whois3
 2010-09-26 02:50:15 [freenode]  Deleted plugin PocoircStatus2
 2010-09-26 02:50:15 [freenode]  Deleted plugin ISupport3

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=head1 LICENSE AND COPYRIGHT

Copyright 2010 Hinrik E<Ouml>rn SigurE<eth>sson

This program is free software, you can redistribute it and/or modify
it under the same terms as Perl itself.

=cut
