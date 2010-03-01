use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME                => 'Net::STOMP::Client',
    AUTHOR              => q{Lionel Cons <lionel.cons@cern.ch>},
    VERSION             => '0.8',
    ABSTRACT_FROM       => 'lib/Net/STOMP/Client.pm',
    ($ExtUtils::MakeMaker::VERSION >= 6.3002
      ? ('LICENSE'=> 'perl')
      : ()),
    PL_FILES            => {},
    PREREQ_PM => {
        'IO::Select'       => 0,
        'IO::Socket::INET' => 0,
        'IO::Socket::SSL'  => 0,
        'List::Util'       => 0,
        'Test::More'       => 0,
    },
    dist                => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean               => { FILES => 'Net-STOMP-Client-*' },
);
