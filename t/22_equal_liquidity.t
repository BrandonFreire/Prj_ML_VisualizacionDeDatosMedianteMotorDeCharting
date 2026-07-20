use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Indicators::Liquidity;

sub level {
    my ($index, $price, $side) = @_;
    return {
        index => $index, price => $price, side => $side,
        confirmed_at => $index + 1,
        is_eqh => 0, is_eql => 0,
    };
}

my @candles = map { { high => 99, low => 91, close => 95 } } 0..15;
my @atr = (1) x @candles;
my @highs = (
    level(1, 100.00, 'sh'),
    level(5, 100.05, 'sh'),
    level(9, 100.03, 'sh'),
);
Market::Indicators::Liquidity::_mark_equal_levels(
    \@highs, \@atr, \@candles, 'high', 0.10,
);
ok($highs[0]{is_eqh} && $highs[1]{is_eqh}, 'dos máximos dentro de 0.10 ATR forman EQH');
is($highs[1]{eq_pair}, 1, 'el segundo máximo referencia el primero');
cmp_ok(abs($highs[1]{eq_price} - 100.025), '<', 1e-10,
    'el nivel EQH usa el precio medio horizontal del par');
is($highs[2]{eq_pair}, 5, 'un tercer máximo se enlaza con el pivote válido más cercano');

my @consumed_candles = map { { high => 99, low => 91, close => 95 } } 0..8;
$consumed_candles[3]{high} = 100.30;
my @consumed = (level(1, 100.00, 'sh'), level(6, 100.04, 'sh'));
Market::Indicators::Liquidity::_mark_equal_levels(
    \@consumed, [(1) x @consumed_candles], \@consumed_candles, 'high', 0.10,
);
ok(!$consumed[1]{is_eqh}, 'no crea EQH si el primer máximo ya fue consumido');

my @outside = (level(1, 100.00, 'sh'), level(5, 100.11, 'sh'));
Market::Indicators::Liquidity::_mark_equal_levels(
    \@outside, \@atr, \@candles, 'high', 0.10,
);
ok(!$outside[1]{is_eqh}, 'rechaza máximos fuera de la tolerancia ATR');

my @lows = (level(2, 90.00, 'sl'), level(7, 89.94, 'sl'));
Market::Indicators::Liquidity::_mark_equal_levels(
    \@lows, \@atr, \@candles, 'low', 0.10,
);
ok($lows[1]{is_eql}, 'la misma regla detecta EQL de forma simétrica');
is($lows[1]{eq_pair}, 2, 'el EQL conserva el índice del mínimo anterior');

eval { Market::Indicators::Liquidity->new(eq_tolerance_atr => 0) };
like($@, qr/eq_tolerance_atr/, 'rechaza una tolerancia EQH/EQL inválida');

done_testing();
