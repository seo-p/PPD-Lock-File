#!perl -T
use 5.006;
use strict;
use warnings;
use Test::More;

plan tests => 1;

BEGIN {
    use_ok( 'PPD::Lock::File' ) || print "Bail out!\n";
}

diag( "Testing PPD::Lock::File $PPD::Lock::File::VERSION, Perl $], $^X" );
