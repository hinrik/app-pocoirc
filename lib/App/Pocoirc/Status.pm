package App::Pocoirc::Status;

use strict;
use warnings FATAL => 'all';
use Carp;
use POE::Component::IRC::Common qw(irc_to_utf8 strip_color strip_formatting);
use POE::Component::IRC::Plugin qw(PCI_EAT_NONE);

sub new {
    my ($package) = shift;
    croak "$package requires an even number of arguments" if @_ & 1;
    return bless { @_ }, $package;
}

sub PCI_register {
    my ($self, $irc, %args) = @_;

    $self->{status}{$irc} = $args{status};
    $irc->raw_events(1) if $self->{Verbose};

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

sub _normalize {
    my ($line) = @_;
    $line = irc_to_utf8($line);
    $line = strip_color($line);
    $line = strip_formatting($line);
    return $line;
}

sub S_connected {
    my ($self, $irc) = splice @_, 0, 2;
    my $address = ${ $_[0] };
    $self->{status}{$irc}->('debug', 'Event S_connected') if $self->{Trace};
    $self->{status}{$irc}->('normal', "Connected to server $address");
    return PCI_EAT_NONE;
}

sub S_disconnected {
    my ($self, $irc) = splice @_, 0, 2;
    my $server = ${ $_[0] };
    $self->{status}{$irc}->('debug', 'Event S_disconnected') if $self->{Trace};
    $self->{status}{$irc}->('normal', "Disconnected from server $server");
    return PCI_EAT_NONE;
}

sub S_snotice {
    my ($self, $irc) = splice @_, 0, 2;
    my $notice = _normalize(${ $_[0] });
    $self->{status}{$irc}->('debug', 'Event S_snotice') if $self->{Trace};
    $self->{status}{$irc}->('normal', "Server notice: $notice");
    return PCI_EAT_NONE;
}

sub S_notice {
    my ($self, $irc) = splice @_, 0, 2;
    my $sender = _normalize(${ $_[0] });
    my $notice = _normalize(${ $_[2] });

    $self->{status}{$irc}->('debug', 'Event S_notice') if $self->{Trace};
    if (defined $irc->server_name() && $sender ne $irc->server_name()) {
        return PCI_EAT_NONE;
    }

    $self->{status}{$irc}->('normal', "Server notice: $notice");
    return PCI_EAT_NONE;
}

sub S_001 {
    my ($self, $irc) = splice @_, 0, 2;
    my $server = ${ $_[0] };
    my $nick = $irc->nick_name();
    $self->{status}{$irc}->('debug', 'Event S_001') if $self->{Trace};
    $self->{status}{$irc}->('normal', "Logged in to server $server with nick $nick");
    return PCI_EAT_NONE;
}

sub S_identified {
    my ($self, $irc) = splice @_, 0, 2;
    my $nick = $irc->nick_name();
    $self->{status}{$irc}->('debug', 'Event S_identified') if $self->{Trace};
    $self->{status}{$irc}->('normal', "Identified with NickServ as $nick");
    return PCI_EAT_NONE;
}

sub S_nick {
    my ($self, $irc) = splice @_, 0, 2;
    my $user    = _normalize(${ $_[0] });
    my $newnick = _normalize(${ $_[1] });
    my $oldnick = (split /!/, $user)[0];

    $self->{status}{$irc}->('debug', 'Event S_nick') if $self->{Trace};
    return PCI_EAT_NONE if $newnick ne $irc->nick_name();
    $self->{status}{$irc}->('normal', "Nickname changed from $oldnick to $newnick");
    return PCI_EAT_NONE;
}

sub S_join {
    my ($self, $irc) = splice @_, 0, 2;
    my $user = _normalize(${ $_[0] });
    my $chan = _normalize(${ $_[1] });
    my $nick = (split /!/, $user)[0];

    $self->{status}{$irc}->('debug', 'Event S_join') if $self->{Trace};
    return PCI_EAT_NONE if $nick ne $irc->nick_name();
    $self->{status}{$irc}->('normal', "Joined channel $chan");
    return PCI_EAT_NONE;
}

sub S_part {
    my ($self, $irc) = splice @_, 0, 2;
    my $user   = _normalize(${ $_[0] });
    my $chan   = _normalize(${ $_[1] });
    my $reason = ref $_[2] eq 'SCALAR' ? _normalize(${ $_[2] }) : '';
    my $nick   = (split /!/, $user)[0];

    $self->{status}{$irc}->('debug', 'Event S_part') if $self->{Trace};
    return PCI_EAT_NONE if $nick ne $irc->nick_name();
    my $msg = "Parted channel $chan";
    $msg .= " ($reason)" if $reason ne '';
    $self->{status}{$irc}->('normal', $msg);
    return PCI_EAT_NONE;
}

sub S_kick {
    my ($self, $irc) = splice @_, 0, 2;
    my $kicker = _normalize(${ $_[0] });
    my $chan   = _normalize(${ $_[1] });
    my $victim = _normalize(${ $_[2] });
    my $reason = _normalize(${ $_[3] });
    $kicker    = (split /!/, $kicker)[0];

    $self->{status}{$irc}->('debug', 'Event S_kick') if $self->{Trace};
    return PCI_EAT_NONE if $victim ne $irc->nick_name();
    my $msg = "Kicked from $chan by $kicker";
    $msg .= " ($reason)" if length $reason;
    $self->{status}{$irc}->('normal', $msg);
    return PCI_EAT_NONE;
}

sub S_error {
    my ($self, $irc) = splice @_, 0, 2;
    my $error = _normalize(${ $_[0] });
    $self->{status}{$irc}->('debug', 'Event S_error') if $self->{Trace};
    $self->{status}{$irc}->('normal', "Error from IRC server: $error");
    return PCI_EAT_NONE;
}

sub S_quit {
    my ($self, $irc) = splice @_, 0, 2;
    my $user   = _normalize(${ $_[0] });
    my $reason = _normalize(${ $_[1] });
    my $nick   = (split /!/, $user)[0];

    $self->{status}{$irc}->('debug', 'Event S_quit') if $self->{Trace};
    return PCI_EAT_NONE if $nick ne $irc->nick_name();
    my $msg = 'Quit from IRC';
    $msg .= " ($reason)" if length $reason;
    $self->{status}{$irc}->('normal', $msg);
    return PCI_EAT_NONE;
}

sub S_shutdown {
    my ($self, $irc) = splice @_, 0, 2;
    $self->{status}{$irc}->('debug', 'Event S_shutdown') if $self->{Trace};
    $self->{status}{$irc}->('normal', 'Shutting down');
    return PCI_EAT_NONE;
}

sub S_socketerr {
    my ($self, $irc) = splice @_, 0, 2;
    my $reason = _normalize(${ $_[0] });
    $self->{status}{$irc}->('debug', 'Event S_socketerr') if $self->{Trace};
    $self->{status}{$irc}->('normal', "Failed to connect to server: $reason");
    return PCI_EAT_NONE;
}

sub S_socks_failed {
    my ($self, $irc) = splice @_, 0, 2;
    my $reason = _normalize(${ $_[0] });
    $self->{status}{$irc}->('debug', 'Event S_socks_failed') if $self->{Trace};
    $self->{status}{$irc}->('normal', "Failed to connect to SOCKS server: $reason");
    return PCI_EAT_NONE;
}

sub S_socks_rejected {
    my ($self, $irc) = splice @_, 0, 2;
    my $code = ${ $_[0] };
    $self->{status}{$irc}->('debug', 'Event S_socks_rejected') if $self->{Trace};
    $self->{status}{$irc}->('normal', "Connection rejected by SOCKS server (code $code)");
    return PCI_EAT_NONE;
}

sub S_raw {
    my ($self, $irc) = splice @_, 0, 2;
    my $raw = _normalize(${ $_[0] });
    return PCI_EAT_NONE if !$self->{Verbose};
    $self->{status}{$irc}->('debug', "Raw: $raw");
    return PCI_EAT_NONE;
}

sub _default {
    my ($self, $irc, $event) = splice @_, 0, 3;
    return PCI_EAT_NONE if !$self->{Trace};
    return PCI_EAT_NONE if $event =~ /^S_plugin_/;
    $self->{status}{$irc}->('debug', "Event $event") if $self->{Trace};
    return PCI_EAT_NONE;
}

1;

=encoding utf8

=head1 NAME

App::Pocoirc::Status - A PoCo-IRC plugin which logs IRC status

=head1 DESCRIPTION

This plugin is used internally by L<App::Pocoirc|App::Pocoirc>. No need for
you to use it.

=head1 AUTHOR

Hinrik E<Ouml>rn SigurE<eth>sson, hinrik.sig@gmail.com

=cut
