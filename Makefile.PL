use 5.006;
use strict;
use warnings;
use ExtUtils::MakeMaker;

WriteMakefile(
    NAME             => 'PPD::Lock::File',
    AUTHOR           => q{H.Seo <seo@psoft.co.jp>},
    VERSION_FROM     => 'lib/PPD/Lock/File.pm',
    ABSTRACT_FROM    => 'lib/PPD/Lock/File.pm',
    LICENSE          => 'artistic_2',
    PL_FILES         => {},
    MIN_PERL_VERSION => '5.006',
    CONFIGURE_REQUIRES => {
        'ExtUtils::MakeMaker' => '0',
    },
    BUILD_REQUIRES => {
        'Test::More'		=> '0',
        'Path::Class'		=> '0',
        'Time::HiRes'		=> '0',
        'Carp'				=> '0',
        'File::Path'		=> '0',
        'Test::Exception'	=> '0',
        'File::Spec'		=> '0',
        'POSIX'				=> '0',
        'Data::Dumper'		=> '0',
    },
    PREREQ_PM => {
        #'ABC'              => '1.6',
        #'Foo::Bar::Module' => '5.0401',
    },
    dist  => { COMPRESS => 'gzip -9f', SUFFIX => 'gz', },
    clean => { FILES => 'PPD-Lock-File-*' },
);
