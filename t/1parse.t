#!perl

use strict;
use warnings;
use Net::STOMP::Client::Error;
use Net::STOMP::Client::Frame;
use Test::More tests => 67;
use Encode qw();

# errors will not trigger die()
$Net::STOMP::Client::Error::Die = 0;

use constant EXPECT_ERROR      => 1;
use constant EXPECT_INCOMPLETE => 2;
use constant EXPECT_COMPLETE   => 3;

sub test ($$$;$) {
    my($name, $expect, $data, $version) = @_;
    my($strip, $frame);

    ($strip = $data) =~ s/^\n+//;
    $Net::STOMP::Client::Error::Message = "";
    $frame = Net::STOMP::Client::Frame::_decode(\$data, version => $version);
    if ($expect == EXPECT_ERROR) {
	ok(!defined($frame), "$name (frame)");
	ok(length($Net::STOMP::Client::Error::Message), "$name (error)");
	is($data, $strip, "$name (data)");
    } elsif ($expect == EXPECT_INCOMPLETE) {
	ok(defined($frame) && !$frame, "$name (frame)");
	is($Net::STOMP::Client::Error::Message, "", "$name (error)");
	is($data, $strip, "$name (data)");
    } elsif ($expect == EXPECT_COMPLETE) {
	ok(defined($frame) && ref($frame), "$name (frame)");
	is($Net::STOMP::Client::Error::Message, "", "$name (error)");
	is($data, "", "$name (data)");
    } else {
	die;
    }
    return($frame);
}

test("empty", EXPECT_INCOMPLETE, "");
test("newline", EXPECT_INCOMPLETE, "\n");
test("newlines", EXPECT_INCOMPLETE, "\n" x 7);
test("incomplete", EXPECT_INCOMPLETE, "FOO");
test("incomplete", EXPECT_INCOMPLETE, "FOO\n");
test("incomplete", EXPECT_INCOMPLETE, "FOO\n\n");
test("no headers + no body", EXPECT_COMPLETE, "FOO\n\n\0");
test("no headers", EXPECT_COMPLETE, "FOO\n\nbody\0");
test("no body", EXPECT_COMPLETE, "FOO\nid:123\n\n\0");
test("complete", EXPECT_COMPLETE, "FOO\nid:123\n\nbody\0");
test("complete + empty header", EXPECT_COMPLETE, "FOO\nid:\n\nbody\0");
test("complete + noise", EXPECT_COMPLETE, "\nFOO\nid:123\n\nbody\0\n");

test("bad command", EXPECT_ERROR, "foo\n\n\0");
test("bad headers", EXPECT_ERROR, "FOO\nid=123\n\n\0");
test("bad headers", EXPECT_ERROR, "FOO\n:123\n\n\0");
test("bad end-of-frame", EXPECT_ERROR, "FOO\ncontent-length:4\n\nbody\n");

test("no escape (1.0)", EXPECT_COMPLETE, "FOO\nfoo:bar\\gag\n\n\0", "1.0");
test("bad escape (1.1)", EXPECT_ERROR,   "FOO\nfoo:bar\\gag\n\n\0", "1.1");

my($f, $d, $s, $e);

$d = "FOO\nid: 123 \nid: 456\n\nbody\0";
$f = Net::STOMP::Client::Frame::_decode(\$d, version => "1.0");
is($f->command(), "FOO", "command (1.0)");
is($f->header("id"), "456", "header (1.0)");
is($f->body(), "body", "body (1.0)");

$d = "FOO\nid: 123 \nid: 456\n\nbody\0";
$f = Net::STOMP::Client::Frame::_decode(\$d, version => "1.1");
is($f->command(), "FOO", "command (1.1)");
is($f->header("id"), " 123 ", "header (1.1)");
is($f->body(), "body", "body (1.1)");

$s = "Théâtre Français";
$e = Encode::encode("UTF-8", $d=$s, Encode::FB_CROAK);

$d = "FOO\nid:$e\n\nbody\0";
$f = Net::STOMP::Client::Frame::_decode(\$d, version => "1.0");
is($f->header("id"), $e, "header (UTF-8 1.0)");

$d = "FOO\nid:$e\n\nbody\0";
$f = Net::STOMP::Client::Frame::_decode(\$d, version => "1.1");
is($f->header("id"), $s, "header (UTF-8 1.1)");

$d = "FOO\ncontent-type:text/plain\n\n$e\0";
$f = Net::STOMP::Client::Frame::_decode(\$d, version => "1.0");
is($f->body(), $e, "body (UTF-8 1.0)");

$d = "FOO\ncontent-type:text/plain\n\n$e\0";
$f = Net::STOMP::Client::Frame::_decode(\$d, version => "1.1");
is($f->body(), $s, "body (UTF-8 1.1)");

$d = "FOO\ncontent-type:application/unknown\n\n$e\0";
$f = Net::STOMP::Client::Frame::_decode(\$d, version => "1.1");
is($f->body(), $e, "body (UTF-8 1.1)");

$d = "FOO\nid:aaa\\\\bbb\\cccc\\nddd\n\nbody\0";
$f = Net::STOMP::Client::Frame::_decode(\$d, version => "1.0");
is($f->header("id"), "aaa\\\\bbb\\cccc\\nddd", "header (escape 1.0)");

$d = "FOO\nid:aaa\\\\bbb\\cccc\\nddd\n\nbody\0";
$f = Net::STOMP::Client::Frame::_decode(\$d, version => "1.1");
is($f->header("id"), "aaa\\bbb:ccc\nddd", "header (escape 1.1)");
