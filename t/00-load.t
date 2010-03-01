#!perl -T

use Test::More tests => 1;

BEGIN {
    use_ok( 'Net::STOMP::Client' ) || print "Bail out!\n";
}

diag( "Testing Net::STOMP::Client $Net::STOMP::Client::VERSION, Perl $], $^X" );
