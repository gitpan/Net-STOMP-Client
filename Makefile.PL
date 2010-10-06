use strict;
use warnings;
use ExtUtils::MakeMaker;

my(%param, $emv, $name);

%param = (
    NAME                   => 'Net::STOMP::Client',
    AUTHOR                 => 'Lionel Cons <lionel.cons@cern.ch>',
    VERSION                => '0.9.4',
    ABSTRACT_FROM          => 'lib/Net/STOMP/Client.pm',
    LICENSE                => 'perl',
    PL_FILES               => {},
    BUILD_REQUIRES => {
        'Test::More'       => 0,
        # Test::Pod is optional
    },
    PREREQ_PM => {
        'Encode'           => 0,
        'Exporter'         => 0,
        'IO::Select'       => 0,
        'IO::Socket::INET' => 0,
        # IO::Socket::SSL is optional
        'List::Util'       => 0,
        'Time::HiRes'      => 0,
        'UNIVERSAL'        => 0,
    },
    dist                   => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean                  => { FILES => 'Net-STOMP-Client-*' },
);

($emv = $ExtUtils::MakeMaker::VERSION) =~ s/_//;
if ($emv < 6.5503) {
    # missing BUILD_REQUIRES
    foreach $name (keys(%{ $param{BUILD_REQUIRES} })) {
	$param{PREREQ_PM}{$name} = $param{BUILD_REQUIRES}{$name};
    }
    delete($param{BUILD_REQUIRES});
}
if ($emv < 6.31) {
    # missing LICENSE
    delete($param{LICENSE});
}

WriteMakefile(%param);
