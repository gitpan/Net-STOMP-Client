#!perl

use strict;
use warnings;
use Net::STOMP::Client::Error;
use Net::STOMP::Client::Frame;
use Test::More tests => 19;

# errors will not trigger die()
$Net::STOMP::Client::Error::Die = 0;

# we use the maximum checking level
$Net::STOMP::Client::Frame::CheckLevel = 3;

sub test ($$$$;$) {
    my($ok, $command, $headers, $body, $version) = @_;
    my($frame, $check, $what);

    $Net::STOMP::Client::Error::Message = "";
    $frame = Net::STOMP::Client::Frame->new(
	command => $command,
	headers => $headers,
	body    => $body,
    );
    $check = $frame->check($version);
    $what = $command;
    $what .= " {" . join("+", sort(keys(%$headers))) . "}";
    $what .= " ($version)" if $version;
    if ($ok) {
	is($Net::STOMP::Client::Error::Message, "", $what);
    } else {
	ok($Net::STOMP::Client::Error::Message, $what);
    }
}

# invalid command
test(0, "FOOBAR", {}, "");

# missing header for 1.1
test(0, "CONNECT", { login => "", passcode => "" }, "", "1.1");
# invalid heart-beat
test(0, "CONNECT", { login => "", passcode => "", host => "foo", "accept-version" => "1.1", "heart-beat" => "500"  }, "", "1.1");
# unexpected header
test(0, "CONNECT", { login => "", passcode => "", foobar => 123 }, "");
# unexpected body
test(0, "CONNECT", { login => "", passcode => "" }, "body");
# ok
test(1, "CONNECT", {}, "");
test(1, "CONNECT", { login => "", passcode => "" }, "");
test(1, "CONNECT", { login => "", passcode => "", host => "foo", "accept-version" => "1.1" }, "", "1.1");
test(1, "CONNECT", { login => "", passcode => "", host => "foo", "accept-version" => "1.1", "heart-beat" => "500,0" }, "", "1.1");

# missing header for 1.1
test(0, "CONNECTED", { session => 123 }, "", "1.1");
# unexpected header
test(0, "CONNECTED", { session => 123, foobar => 123 }, "");
# ok
test(1, "CONNECTED", { session => 123 }, "");
test(1, "CONNECTED", { session => 123, version => "1.1" }, "", "1.1");

# ok
test(1, "SEND", { destination => "foo" }, "");
test(1, "SEND", { destination => "foo" }, "body");
test(1, "SEND", { destination => "foo", foobar => 123 }, "");

# ok
test(1, "MESSAGE", { "message-id" => 1, destination => "foo" }, "");
test(1, "MESSAGE", { "message-id" => 1, destination => "foo" }, "body");
test(1, "MESSAGE", { "message-id" => 1, destination => "foo", foobar => 123 }, "");
