use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", '.';
use Test::More;

use MarketTestUtil qw(make_market atr_candles);
use Market::Indicators::ATR;

sub approx {
    my ($actual, $expected, $name) = @_;
    cmp_ok(abs($actual - $expected), '<', 1e-10, $name);
}

my $candles = atr_candles();
my $market  = make_market($candles);
my $atr     = Market::Indicators::ATR->new(2);
$atr->compute_all($market);

my $values = $atr->get_values();
is(scalar @$values, 4, 'ATR batch conserva una salida por vela');
ok(!defined $values->[0], 'ATR permanece indefinido durante el warm-up de Wilder');
approx($values->[1], 2.5,   'semilla Wilder es la media de los dos TR iniciales');
approx($values->[2], 2.75,  'Wilder se aplica después de la semilla');
approx($values->[3], 2.875, 'Wilder mantiene la serie incremental');

my $incremental_market = make_market([]);
my $incremental_atr    = Market::Indicators::ATR->new(2);
for my $c (@$candles) {
    $incremental_market->add_candle({ %$c });
    $incremental_atr->update_last($incremental_market);
}

my $incremental_values = $incremental_atr->get_values();
is(scalar @$incremental_values, scalar @$values, 'ATR incremental emite una salida por vela añadida');
for my $i (0 .. $#$values) {
    if (!defined $values->[$i]) {
        ok(!defined $incremental_values->[$i],
            "batch e incremental conservan warm-up en vela $i");
    }
    else {
        approx($incremental_values->[$i], $values->[$i],
            "batch e incremental coinciden en vela $i");
    }
}

$atr->reset();
is_deeply($atr->get_values(), [], 'reset elimina el estado calculado de ATR');

done_testing();
