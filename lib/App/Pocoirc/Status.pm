package App::Pocoirc::Status;

use strict;
use warnings FATAL => 'all';
use Carp;
use POE::Component::IRC::Plugin qw(PCI_EAT_NONE);

sub new {
    my ($package) = shift;
    croak "$package requires an even number of arguments" if @_ & 1;
    my %self = @_;
    croak "$package requires a Pocoirc argument" if ref $self{Pocoirc} ne 'App::Pocoirc';
    return bless \%self, $package;
}

sub PCI_register {
    my ($self, $irc) = @_;

    $irc->raw_events(1) if $self->{Trace} || $self->{Verbose};

    if ($self->{Trace}) {
        $irc->plugin_register($self, 'SERVER', 'all');
        $irc->plugin_register($self, 'USER', 'all');
    }
    else {
        $irc->plugin_register($self, 'SERVER', qw(
            connected
            disconnected
            snotice
            notice
            001
            identified
            quit
            nick
            join
            part
            kick
            error
            socketerr
            shutdown
            socks_failed
            socks_rejected
            raw
        ));
    }
    return 1;
}

sub PCI_unregister {
    return 1;
}

sub S_connected {
    my ($self, $irc) = splice @_, 0, 2;
    my $address = ${ $_[0] };
    $self->{Pocoirc}->_status("Event S_connected", $irc, 'debug') if $self->{Trace};
    $self->{Pocoirc}->_status("Connected to server $address", $irc);
    return PCI_EAT_NONE;
}

sub S_disconnected {
    my ($self, $irc) = splice @_, 0, 2;
    my $server = ${ $_[0] };
    $self->{Pocoirc}->_status("Event S_disconnected", $irc, 'debug') if $self->{Trace};
    $self->{Pocoirc}->_status("Disconnected from server $server", $irc);
    return PCI_EAT_NONE;
}

sub S_snotice {
    my ($self, $irc) = splice @_, 0, 2;
    my $notice = ${ $_[0] };
    $self->{Pocoirc}->_status("Event S_snotice", $irc, 'debug') if $self->{Trace};
    $self->{Pocoirc}->_status("Server notice: $notice", $irc);
    return PCI_EAT_NONE;
}

sub S_notice {
    my ($self, $irc) = splice @_, 0, 2;
    my $sender = ${ $_[0] };
    my $notice = ${ $_[2] };

    $self->{Pocoirc}->_status("Event S_notice", $irc, 'debug') if $self->{Trace};
    if (defined $irc->server_name() && $sender ne $irc->server_name()) {
        return PCI_EAT_NONE;
    }

    $self->{Pocoirc}->_status("Server notice: $notice", $irc);
    return PCI_EAT_NONE;
}

sub S_001 {
    my ($self, $irc) = splice @_, 0, 2;
    my $server = ${ $_[0] };
    my $nick = $irc->nick_name();
    $self->{Pocoirc}->_status("Event S_001", $irc, 'debug') if $self->{Trace};
    $self->{Pocoirc}->_status("Logged in to server $server with nick $nick", $irc);
    return PCI_EAT_NONE;
}

sub S_identified {
    my ($self, $irc) = splice @_, 0, 2;
    my $nick = $irc->nick_name();
    $self->{Pocoirc}->_status("Event S_identified", $irc, 'debug') if $self->{Trace};
    $self->{Pocoirc}->_status("Identified with NickServ as $nick", $irc);
    return PCI_EAT_NONE;
}

sub S_nick {
    my ($self, $irc) = splice @_, 0, 2;
    my $user    = ${ $_[0] };
    my $newnick = ${ $_[1] };
    my $oldnick = (split /!/, $user)[0];

    $self->{Pocoirc}->_status("Event S_nick", $irc, 'debug') if $self->{Trace};
    return PCI_EAT_NONE if $newnick ne $irc->nick_name();
    $self->{Pocoirc}->_status("Nickname changed from $oldnick to $newnick", $irc);
    return PCI_EAT_NONE;
}

sub S_join {
    my ($self, $irc) = splice @_, 0, 2;
    my $user = ${ $_[0] };
    my $chan = ${ $_[1] };
    my $nick = (split /!/, $user)[0];

    $self->{Pocoirc}->_status("Event S_join", $irc, 'debug') if $self->{Trace};
    return PCI_EAT_NONE if $nick ne $irc->nick_name();
    $self->{Pocoirc}->_status("Joined channel $chan", $irc);
    return PCI_EAT_NONE;
}

sub S_part {
    my ($self, $irc) = splice @_, 0, 2;
    my $user   = ${ $_[0] };
    my $chan   = ${ $_[1] };
    my $reason = ${ $_[2] };
    my $nick   = (split /!/, $user)[0];

    $self->{Pocoirc}->_status("Event S_part", $irc, 'debug') if $self->{Trace};
    return PCI_EAT_NONE if $nick ne $irc->nick_name();
    my $msg = "Parted channel $chan";
    $msg .= " ($reason)" if defined $reason;
    $self->{Pocoirc}->_status($msg, $irc);
    return PCI_EAT_NONE;
}

sub S_kick {
    my ($self, $irc) = splice @_, 0, 2;
    my $kicker = ${ $_[0] };
    my $chan   = ${ $_[1] };
    my $victim = ${ $_[2] };
    my $reason = ${ $_[3] };
    $kicker    = (split /!/, $kicker)[0];

    $self->{Pocoirc}->_status("Event S_kick", $irc, 'debug') if $self->{Trace};
    return PCI_EAT_NONE if $victim ne $irc->nick_name();
    my $msg = "Kicked from $chan by $kicker";
    $msg .= " ($reason)" if length $reason;
    $self->{Pocoirc}->_status($msg, $irc);
    return PCI_EAT_NONE;
}

sub S_error {
    my ($self, $irc) = splice @_, 0, 2;
    my $error = ${ $_[0] };
    $self->{Pocoirc}->_status("Event S_error", $irc, 'debug') if $self->{Trace};
    $self->{Pocoirc}->_status("Error from IRC server: $error", $irc);
    return PCI_EAT_NONE;
}

sub S_quit {
    my ($self, $irc) = splice @_, 0, 2;
    my $user   = ${ $_[0] };
    my $reason = ${ $_[1] };
    my $nick   = (split /!/, $user)[0];

    $self->{Pocoirc}->_status("Event S_quit", $irc, 'debug') if $self->{Trace};
    return PCI_EAT_NONE if $nick ne $irc->nick_name();
    my $msg = 'Quit from IRC';
    $msg .= " ($reason)" if length $reason;
    $self->{Pocoirc}->_status($msg, $irc);
    return PCI_EAT_NONE;
}

sub S_shutdown {
    my ($self, $irc) = splice @_, 0, 2;
    $self->{Pocoirc}->_status("Event S_shutdown", $irc, 'debug') if $self->{Trace};
    $self->{Pocoirc}->_status("Shutting down", $irc);
    return PCI_EAT_NONE;
}

sub S_socketerr {
    my ($self, $irc) = splice @_, 0, 2;
    my $reason = ${ $_[0] };
    $self->{Pocoirc}->_status("Event S_socketerr", $irc, 'debug') if $self->{Trace};
    $self->{Pocoirc}->_status("Failed to connect to server: $reason", $irc);
    return PCI_EAT_NONE;
}

sub S_socks_failed {
    my ($self, $irc) = splice @_, 0, 2;
    my $reason = ${ $_[0] };
    $self->{Pocoirc}->_status("Event S_socks_failed", $irc, 'debug') if $self->{Trace};
    $self->{Pocoirc}->_status("Failed to connect to SOCKS server: $reason", $irc);
    return PCI_EAT_NONE;
}

sub S_socks_rejected {
    my ($self, $irc) = splice @_, 0, 2;
    my $code = ${ $_[0] };
    $self->{Pocoirc}->_status("Event S_socks_rejected", $irc, 'debug') if $self->{Trace};
    $self->{Pocoirc}->_status("Connection rejected by SOCKS server (code $code)", $irc);
    return PCI_EAT_NONE;
}

sub S_raw {
    my ($self, $irc) = splice @_, 0, 2;
    my $raw = ${ $_[0] };
    return PCI_EAT_NONE if !$self->{Verbose};
    $self->{Pocoirc}->_status("->$raw", $irc);
    return PCI_EAT_NONE;
}

sub _default {
    my ($self, $irc, $event) = splice @_, 0, 3;
    return PCI_EAT_NONE if !$self->{Trace};
    return PCI_EAT_NONE if $event =~ /^S_plugin_/;
    $self->{Pocoirc}->_status("Event $event", $irc, 'debug') if $self->{Trace};
    return PCI_EAT_NONE;
}

1;

=encoding utf8

=head1 NAME

App::Pocoirc::Stats - A PoCo-IRC plugin which logs IRC status

=head1 DESCRIPTION

This plugin is used internally by L<App::Pocoirc|App::Pocoirc>. No need for
you to use it.

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=cut
