#+##############################################################################
#                                                                              #
# File: Net/STOMP/Client/IO.pm                                                 #
#                                                                              #
# Description: Input/Output support for Net::STOMP::Client                     #
#                                                                              #
#-##############################################################################

#
# module definition
#

package Net::STOMP::Client::IO;
use strict;
use warnings;
our $VERSION  = "1.8";
our $REVISION = sprintf("%d.%02d", q$Revision: 1.30 $ =~ /(\d+)\.(\d+)/);

#
# Object Oriented definition
#

use Net::STOMP::Client::OO;
our(@ISA) = qw(Net::STOMP::Client::OO);
Net::STOMP::Client::OO::methods(qw(_socket _select _error _last_read _last_write));

#
# used modules
#

use IO::Select qw();
use Net::STOMP::Client::Debug;
use Net::STOMP::Client::Error;
use POSIX qw(:errno_h);
use Time::HiRes qw();

#
# constants
#

use constant MAX_CHUNK => 32768;

#
# constructor
#

sub new : method {
    my($class, $socket, $blocking) = @_;
    my($self, $select);

    unless ($socket and ref($socket) and $socket->isa("IO::Socket")) {
	Net::STOMP::Client::Error::report("Net::STOMP::Client::IO->new(): missing socket");
	return();
    }
    $self = $class->SUPER::new(_socket => $socket);
    if ($blocking) {
	$select = IO::Select->new();
	$socket->blocking(1);
	$select->add($socket);
	$self->_select($select);
	$self->{_blocking} = 1;
    } else {
	$socket->blocking(0);
	$self->{_blocking} = 0;
    }
    $self->{_incoming_buffer} = "";
    $self->{_outgoing_buffer} = "";
    $self->{_outgoing_queue} = [];
    $self->{_outgoing_length} = 0;
    $self->{_ssl} = $socket->isa("IO::Socket::SSL");
    return($self);
}

#
# incoming buffer access (only as a reference)
#

sub incoming_buffer_reference : method {
    my($self) = @_;

    return(\$self->{_incoming_buffer});
}

#
# outgoing buffer access (only its length)
#

sub outgoing_buffer_length : method {
    my($self) = @_;

    return($self->{_outgoing_length});
}

#
# destructor to nicely shutdown+close the socket
#
# reference: http://www.perlmonks.org/?node=108244
#

sub DESTROY {
    my($self) = @_;
    my($socket, $ignored);

    $socket = $self->_socket();
    if ($socket) {
	# call shutdown() without checking if it fails or not since there is
	# not much that can be done in case of failure... unless we use SSL
	# for which it is better not to call shutdown(), see IO::Socket::SSL's
	# man page for more information
	$ignored = shutdown($socket, 2) unless $self->{_ssl};
	# the following will cleanly auto-close the socket
	$self->_socket(undef);
    }
}

#
# write data from outgoing buffer to socket (blocking version)
#

sub _buf2sock : method {
    my($self, $timeout) = @_;
    my($buflen, $maxtime, $written, $data, $chunk, $count, $remaining);

    # we cannot write anything if the socket is in error
    return() if $self->_error();
    # boundary conditions
    $buflen = length($self->{_outgoing_buffer});
    return(0) if $buflen == 0 and not @{ $self->{_outgoing_queue} };
    if ($timeout) {
	return(0) unless $timeout > 0;
	# timer starts now
	$maxtime = Time::HiRes::time() + $timeout;
    }
    # use select() to check if we can write something
    return(0) unless $self->_select()->can_write($timeout);
    # try to write, in a loop, until we are done
    $written = 0;
    while (1) {
	# make sure there is enough data in the outgoing buffer
	while ($buflen < MAX_CHUNK and @{ $self->{_outgoing_queue} }) {
	    $data = shift(@{ $self->{_outgoing_queue} });
	    $self->{_outgoing_buffer} .= $$data;
	    $buflen += length($$data);
	}
	last unless $buflen;
	# write one chunk
	$chunk = $buflen;
	$chunk = MAX_CHUNK if $chunk > MAX_CHUNK;
	$count = syswrite($self->_socket(), $self->{_outgoing_buffer}, $chunk);
	unless (defined($count)) {
	    $self->_error("cannot syswrite(): $!");
	    return();
	}
	# update where we are
	if ($count) {
	    $self->_last_write(Time::HiRes::time());
	    $written += $count;
	    $buflen -= $count;
	    substr($self->{_outgoing_buffer}, 0, $count) = "";
	    $self->{_outgoing_length} -= $count;
	}
	# stop if enough has been written
	last if $buflen == 0 and not @{ $self->{_outgoing_queue} };
	# check where we are with timing
	if (not defined($timeout)) {
	    # timeout = undef => blocking
	    last unless $self->_select()->can_write();
	} elsif ($timeout) {
	    # timeout > 0 => try once more if not too late
	    $remaining = $maxtime - Time::HiRes::time();
	    last if $remaining <= 0;
	    last unless $self->_select()->can_write($remaining);
	} else {
	    # timeout = 0 => non-blocking
	    last unless $self->_select()->can_write(0);
	}
    }
    # return what has been written
    return($written);
}

#
# write data from outgoing buffer to socket (non-blocking version)
#

sub _buf2sock_nb : method {
    my($self, $timeout) = @_;
    my($buflen, $maxtime, $written, $data, $chunk, $count, $remaining);

    # we cannot write anything if the socket is in error
    return() if $self->_error();
    # boundary conditions
    $buflen = length($self->{_outgoing_buffer});
    return(0) if $buflen == 0 and not @{ $self->{_outgoing_queue} };
    if ($timeout) {
	return(0) unless $timeout > 0;
	# timer starts now
	$maxtime = Time::HiRes::time() + $timeout;
    }
    # try to write, in a loop, until we are done
    $written = 0;
    while (1) {
	# make sure there is enough data in the outgoing buffer
	while ($buflen < MAX_CHUNK and @{ $self->{_outgoing_queue} }) {
	    $data = shift(@{ $self->{_outgoing_queue} });
	    $self->{_outgoing_buffer} .= $$data;
	    $buflen += length($$data);
	}
	last unless $buflen;
	# write one chunk
	$chunk = $buflen;
	$chunk = MAX_CHUNK if $chunk > MAX_CHUNK;
	$count = syswrite($self->_socket(), $self->{_outgoing_buffer}, $chunk);
	unless (defined($count)) {
	    if ($! == EAGAIN or $! == EWOULDBLOCK) {
		# we could not write this time
		$count = 0;
	    } else {
		# unexpected error
		$self->_error("cannot syswrite(): $!");
		return();
	    }
	}
	# update where we are
	if ($count) {
	    $self->_last_write(Time::HiRes::time());
	    $written += $count;
	    $buflen -= $count;
	    substr($self->{_outgoing_buffer}, 0, $count) = "";
	    $self->{_outgoing_length} -= $count;
	}
	# stop if enough has been written
	last if $buflen == 0 and not @{ $self->{_outgoing_queue} };
	# check where we are with timing
	if (not defined($timeout)) {
	    # timeout = undef => blocking until we are done
	} elsif ($timeout) {
	    # timeout > 0 => try more if not too late
	    $remaining = $maxtime - Time::HiRes::time();
	    last if $remaining <= 0;
	} else {
	    # timeout = 0 => non-blocking = try only once
	    last;
	}
	# sleep a bit if needed...
	Time::HiRes::sleep(0.01) unless $count;
    }
    # return what has been written
    return($written);
}

#
# read data from socket to incoming buffer (blocking version)
#

sub _sock2buf : method {
    my($self, $timeout) = @_;
    my($count);

    # we cannot read anything if the socket is in error
    return() if $self->_error();
    # boundary conditions
    if ($timeout) {
	return(0) unless $timeout > 0;
    }
    # use select() to check if we can read something
    unless ($self->_select()->can_read($timeout)) {
	# in case of SSL we also check what is pending
	return(0) unless $self->{_ssl} and $self->_socket()->pending();
    }
    # try to read, once only since we do not know when to stop...
    $count = sysread($self->_socket(), $self->{_incoming_buffer}, MAX_CHUNK,
		     length($self->{_incoming_buffer}));
    unless (defined($count)) {
	$self->_error("cannot sysread(): $!");
	return();
    }
    unless ($count) {
	$self->_error("cannot sysread(): EOF");
	return(0);
    }
    # update where we are
    $self->_last_read(Time::HiRes::time());
    # return what has been read
    return($count);
}

#
# read data from socket to incoming buffer (non-blocking version)
#

sub _sock2buf_nb : method {
    my($self, $timeout) = @_;
    my($count, $maxtime, $remaining);

    # we cannot read anything if the socket is in error
    return() if $self->_error();
    # boundary conditions
    if ($timeout) {
	return(0) unless $timeout > 0;
	# timer starts now
	$maxtime = Time::HiRes::time() + $timeout;
    }
    # try to read, in a loop, until we are done
    while (1) {
	# read one chunk
	$count = sysread($self->_socket(), $self->{_incoming_buffer}, MAX_CHUNK,
			 length($self->{_incoming_buffer}));
	if (defined($count)) {
	    # we could read this time
	    unless ($count) {
		$self->_error("cannot sysread(): EOF");
		return(0);
	    }
	    # so far so good, we did read some data so we immediately stop
	    last;
	}
	if ($! != EAGAIN and $! != EWOULDBLOCK) {
	    # unexpected error
	    $self->_error("cannot sysread(): $!");
	    return();
	}
	# we could not read this time
	if (not defined($timeout)) {
	    # timeout = undef => blocking until we are done
	} elsif ($timeout) {
	    # timeout > 0 => try more if not too late
	    $remaining = $maxtime - Time::HiRes::time();
	    return(0) if $remaining <= 0;
	} else {
	    # timeout = 0 => non-blocking = try only once
	    return(0);
	}
	# sleep a bit...
	Time::HiRes::sleep(0.01);
    }
    # update where we are
    $self->_last_read(Time::HiRes::time());
    # return what has been read
    return($count);
}

#
# queue the given data
#

sub queue_data : method {
    my($self, $data) = @_;
    my($me, $length);

    $me = "Net::STOMP::Client::IO::queue_data()";
    unless ($data and ref($data) eq "SCALAR") {
	Net::STOMP::Client::Error::report("%s: unexpected data: %s", $me, $data);
	return();
    }
    $length = length($$data);
    if ($length) {
	push(@{ $self->{_outgoing_queue} }, $data);
	$self->{_outgoing_length} += $length;
    }
    return($length);
}

#
# send the queued data
#

sub send_data : method {
    my($self, $timeout) = @_;
    my($me, $sent);

    $me = "Net::STOMP::Client::IO::send_data()";
    # send some data
    $sent = $self->{_blocking} ? $self->_buf2sock($timeout) : $self->_buf2sock_nb($timeout);
    unless (defined($sent)) {
	Net::STOMP::Client::Error::report("%s: %s", $me, $self->_error());
	return();
    }
    # so far so good
    Net::STOMP::Client::Debug::report(Net::STOMP::Client::Debug::IO,
				      "  sent %d bytes", $sent);
    return($sent);
}

#
# receive some data
#

sub receive_data : method {
    my($self, $timeout) = @_;
    my($me, $received, $more);

    $me = "Net::STOMP::Client::IO::receive_data()";
    # receive some data
    $received = $self->{_blocking} ? $self->_sock2buf($timeout) : $self->_sock2buf_nb($timeout);
    unless (defined($received)) {
	Net::STOMP::Client::Error::report("%s: %s", $me, $self->_error());
	return();
    }
    # so far so good
    Net::STOMP::Client::Debug::report(Net::STOMP::Client::Debug::IO,
				      "  received %d bytes", $received);
    return($received);
}

1;

__END__

=head1 NAME

Net::STOMP::Client::IO - Input/Output support for Net::STOMP::Client

=head1 DESCRIPTION

This module provides Input/Output (I/O) support for Net::STOMP::Client.

It is used internally by Net::STOMP::Client and should not be used
elsewhere.

Two I/O modes are supported: blocking and non-blocking. See the next
two sections for more information.

=head1 BLOCKING I/O

With blocking I/O, the socket is in blocking mode and select() is used
to find out if read() or write() can be attempted. This is the simplest
approach but it may fail (hang) in some situations, especially with SSL.

This was the mode used in Net::STOMP::Client up to version 1.7.

=head1 NON-BLOCKING I/O

With non-blocking I/O, the socket is in non-blocking mode and read()
and write() are called in any case. The code in Net::STOMP::Client::IO
has to handle errors like EAGAIN or EWOULDBLOCK. This is the most
reliable approach (no deadlocks) but it is slightly less efficient.

This mode has been introduced in Net::STOMP::Client version 1.8 and is
the default since then.

=head1 FUNCTIONS

This module provides the following functions and methods:

=over

=item new(SOCKET)

create a new Net::STOMP::Client::IO object

=item queue_data(DATA)

queue (append to the internal outgoing buffer) the given data (a
string reference); return the length of DATA in bytes

=item send_data(TIMEOUT)

send some queued data to the socket; return the total number of bytes
written

=item receive_data(TIMEOUT)

receive some data from the socket and put it in the internal incoming
buffer; return the total number of bytes read

=item incoming_buffer_reference()

return a reference to the internal incoming buffer (a string)

=item outgoing_buffer_length()

return the length of the internal outgoing buffer

=back

=head1 AUTHOR

Lionel Cons L<http://cern.ch/lionel.cons>

Copyright CERN 2010-2012
