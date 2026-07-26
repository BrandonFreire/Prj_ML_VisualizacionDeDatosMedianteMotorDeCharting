use strict;
use warnings;

use Test::More;
use File::Temp qw(tempfile);
use lib '.';
use Market::ML::RawCsv;

my ($fh, $path) = tempfile();
print {$fh} "time,open,high,low,close,Volume\n";
print {$fh} "2026-04-01T00:00:00-05:00,100,102,99,101,10\n";
print {$fh} "2026-04-01T00:01:00-05:00,101,103,100,102,11\n";
close $fh;

my $candles = Market::ML::RawCsv->load_ohlcv_1m(path => $path, require_contiguous => 1);
is(scalar @$candles, 2, 'lee las dos velas OHLCV del CSV crudo');
is($candles->[0]{time}, 1_775_019_600, 'convierte el offset -05:00 a epoch UTC');
is($candles->[1]{time} - $candles->[0]{time}, 60, 'preserva la sincronía de un minuto');

done_testing();
