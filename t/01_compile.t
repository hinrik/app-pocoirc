use strict;
use warnings FATAL => 'all';
use File::Spec::Functions 'catfile';
use Test::More tests => 3;
use Test::Script;

use_ok('App::Pocoirc::Status');
use_ok('App::Pocoirc');

SKIP: {
    skip "There's no blib", 1 unless -d "blib" and -f catfile qw(blib script pocoirc);
    script_compiles(catfile('bin', 'pocoirc'));
};
