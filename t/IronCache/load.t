#!perl -T
use 5.006;
use strict;
use warnings FATAL => 'all';
use Test::More;

require IO::Iron::Applications::IronCache::Functionality;

use Log::Any::Adapter ('Stderr'); # Activate to get all log messages.

plan tests => 2;

BEGIN {
	use_ok('IO::Iron::Applications::IronCache::Functionality') || print "Bail out!\n";
	can_ok('IO::Iron::Applications::IronCache::Functionality', 'list_caches') || print "Bail out!\n";
}


diag("Testing IO::Iron::Applications::IronCache::Functionality, Perl $], $^X");

