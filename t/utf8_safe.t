use Test::More;
use strict;
use utf8;

use_ok('Combust::Util', 'utf8_safe');

is(utf8_safe("æøå – ®"), "æøå – ®", 'utf8_safe()');

done_testing();
