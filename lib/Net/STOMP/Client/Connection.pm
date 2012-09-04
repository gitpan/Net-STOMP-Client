#+##############################################################################
#                                                                              #
# File: Net/STOMP/Client/Connection.pm                                         #
#                                                                              #
# Description: Connection support for Net::STOMP::Client                       #
#                                                                              #
#-##############################################################################

#
# module definition
#

package Net::STOMP::Client::Connection;
use strict;
use warnings;
our $VERSION  = "1.7_5";
our $REVISION = sprintf("%d.%02d", q$Revision: 1.2 $ =~ /(\d+)\.(\d+)/);

#
# used modules
#

use IO::Socket::INET;
use List::Util qw(shuffle);
use Net::STOMP::Client::Error;
use Net::STOMP::Client::Peer;
use Time::HiRes qw();

#
# connect to the server (low level)
#

sub _new_low ($$$$%) {
    my($caller, $proto, $host, $port, %sockopt) = @_;
    my($socket);

    # options sanity
    $sockopt{Proto} = "tcp"; # yes, even SSL is TCP...
    $sockopt{PeerAddr} = $host;
    $sockopt{PeerPort} = $port;
    # from now on, the errors are non-fatal and must be checked by the caller
    local $Net::STOMP::Client::Error::Die = 0;
    # try to connect
    if ($proto =~ /\b(ssl)\b/) {
	# with SSL
	unless ($IO::Socket::SSL::VERSION) {
	    eval { require IO::Socket::SSL };
	    if ($@) {
		Net::STOMP::Client::Error::report
		    ("%s: cannot load IO::Socket::SSL: %s", $caller, $@);
		return();
	    }
	}
	$socket = IO::Socket::SSL->new(%sockopt);
	unless ($socket) {
	    Net::STOMP::Client::Error::report
		("%s: cannot SSL connect to %s:%d: %s", $caller, $sockopt{PeerAddr},
		 $sockopt{PeerPort}, IO::Socket::SSL::errstr());
	    return();
	}
    } else {
	# with TCP
	$socket = IO::Socket::INET->new(%sockopt);
	unless ($socket) {
	    Net::STOMP::Client::Error::report
		("%s: cannot connect to %s:%d: %s", $caller, $sockopt{PeerAddr},
		 $sockopt{PeerPort}, $!);
	    return();
	}
	unless (binmode($socket)) {
	    Net::STOMP::Client::Error::report
		("%s: cannot binmode(socket): %s", $caller, $!);
	    return();
	}
    }
    # so far so good...
    return($socket);
}

#
# connect to the server (high level)
#

sub _new_high ($$$%) {
    my($caller, $peers, $sockopt, %option) = @_;
    my(@list, $count, $peer, $socket);

    $count = 0;
    while (1) {
	@list = $option{randomize} ? shuffle(@$peers) : @$peers;
	foreach $peer (@list) {
	    $socket = _new_low($caller, $peer->proto(), $peer->host(), $peer->port(),
			       %$sockopt);
	    if ($socket) {
		# keep track of the address we are connected to
		$peer->addr($socket->peerhost());
		return($socket, $peer);
	    }
	    $count++;
	    if (defined($option{max_attempt})) {
		last if $count >= $option{max_attempt};
	    }
	    if ($option{sleep}) {
		Time::HiRes::sleep($option{sleep});
		if ($option{multiplier}) {
		    $option{sleep} *= $option{multiplier};
		    if ($option{max_sleep} and $option{sleep} > $option{max_sleep}) {
			$option{sleep} = $option{max_sleep};
			delete($option{multiplier});
		    }
		}
	    }
	}
	if (defined($option{max_attempt})) {
	    last if $count >= $option{max_attempt};
	}
	last unless keys(%option);
    }
    # we only report the last error message...
    Net::STOMP::Client::Error::report("%s", $Net::STOMP::Client::Error::Message);
    return();
}

#
# connect to the server (given a uri)
#
# see: http://activemq.apache.org/failover-transport-reference.html
#

sub _uris2peers ($@) {
    my($caller, @uris) = @_;
    my($uri, @peers);

    foreach $uri (@uris) {
	unless ($uri =~ /^(tcp|ssl|stomp|stomp\+ssl):\/\/([\w\.\-]+):(\d+)\/?$/) {
	    Net::STOMP::Client::Error::report("%s: unexpected server uri: %s", $caller, $uri);
	    return();
	}
	push(@peers, Net::STOMP::Client::Peer->new(
	    proto => $1,
	    host  => $2,
	    port  => $3,
	));
    }
    return(\@peers);
}

sub _new_uri ($$%) {
    my($caller, $uri, %sockopt) = @_;
    my($path, $fh, $line, @list, $peers, %option);

    while (1) {
	if ($uri =~ /^file:(.+)$/) {
	    # list of uris stored in a file, one per line
	    @list = ();
	    $path = $1;
	    unless (open($fh, "<", $path)) {
		Net::STOMP::Client::Error::report
		    ("%s: cannot open %s: %s", $caller, $path, $!);
		return();
	    }
	    while (defined($line = <$fh>)) {
		$line =~ s/\#.*//;
		$line =~ s/\s+//g;
		push(@list, $line) if length($line);
	    }
	    unless (close($fh)) {
		Net::STOMP::Client::Error::report
		    ("%s: cannot close %s: %s", $caller, $path, $!);
		return();
	    }
	    if (@list == 1) {
		# if only one, allow failover syntax
		$uri = shift(@list);
	    } else {
		$peers = _uris2peers($caller, @list);
		last;
	    }
	} elsif ($uri =~ /^failover:(\/\/)?\(([\w\.\-\:\/\,]+)\)(\?[\w\=\-\&]+)?$/) {
	    # failover with options (only "randomize" is supported)
	    $line = $3;
	    $peers = _uris2peers($caller, split(/,/, $2));
	    %option = (randomize => 1, sleep => 0.01, max_sleep => 30, multiplier => 2);
	    if ($line) {
		$option{multiplier} = $2 if $line =~ /\b(backOffMultiplier=(\d+(\.\d+)?))\b/;
		$option{multiplier} = 0 if $line =~ /\b(useExponentialBackOff=false)\b/;
		$option{randomize} = 0 if $line =~ /\b(randomize=false)\b/;
		$option{sleep} = $2/1000 if $line =~ /\b(initialReconnectDelay=(\d+))\b/;
		$option{max_sleep} = $2/1000 if $line =~ /\b(maxReconnectDelay=(\d+))\b/;
		$option{max_attempt} = $2+1 if $line =~ /\b(maxReconnectAttempts=(\d+))\b/;
	    }
	    last;
	} elsif ($uri =~ /^failover:([\w\.\-\:\/\,]+)$/) {
	    # failover without options
	    $peers = _uris2peers($caller, split(/,/, $1));
	    %option = (randomize => 1, sleep => 0.01, max_sleep => 30, multiplier => 2);
	    last;
	} else {
	    $peers = _uris2peers($caller, $uri);
	    last;
	}
    }
    return() unless $peers;
    unless (@$peers) {
	Net::STOMP::Client::Error::report("%s: empty server uri: %s", $caller, $uri);
	return();
    }
    return(_new_high($caller, $peers, \%sockopt, %option));
}

#
# connect to the server (given a host+port)
#

sub _new_host_port ($$$%) {
    my($caller, $host, $port, %sockopt) = @_;
    my($peer);

    $peer = Net::STOMP::Client::Peer->new(
	proto => grep(/^SSL_/, keys(%sockopt)) ? "ssl" : "tcp",
	host  => $host,
	port  => $port,
    );
    return(_new_high($caller, [$peer], \%sockopt));
}

#
# connect to the server
#

sub _new ($$$%) {
    my($caller, $host, $port, $uri, %sockopt) = @_;

    if ($uri) {
	# uri
	if ($host) {
	    Net::STOMP::Client::Error::report
		("%s: unexpected server host: %s", $caller, $host);
	    return();
	}
	if ($port) {
	    Net::STOMP::Client::Error::report
		("%s: unexpected server port: %s", $caller, $port);
	    return();
	}
	return(_new_uri($caller, $uri, %sockopt));
    }
    # host + port
    unless ($host) {
	Net::STOMP::Client::Error::report("%s: missing server host", $caller);
	return();
    }
    unless ($port) {
	Net::STOMP::Client::Error::report("%s: missing server port", $caller);
	return();
    }
    return(_new_host_port($caller, $host, $port, %sockopt));
}

1;

__END__

=head1 NAME

Net::STOMP::Client::Connection - Connection support for Net::STOMP::Client

=head1 DESCRIPTION

This module provides connection support for Net::STOMP::Client.

It is used internally by Net::STOMP::Client and should not be used
elsewhere.

=head1 AUTHOR

Lionel Cons L<http://cern.ch/lionel.cons>

Copyright CERN 2012
