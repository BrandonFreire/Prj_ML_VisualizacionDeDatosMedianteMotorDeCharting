use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Indicators::InternalZigZag;
use Market::Indicators::ATR;
use Market::MarketData;

sub candle {
    my ($i, $high, $low, $open, $close) = @_;
    $open  = ($high + $low) / 2 unless defined $open;
    $close = ($high + $low) / 2 unless defined $close;
    return { time => $i * 60, open => $open, high => $high, low => $low, close => $close, volume => 1000 };
}

sub atr { return [ map { $_[1] } @{ $_[0] } ]; }

my $candles = [
    candle(0, 10, 9), candle(1, 12, 10), candle(2, 14, 11), candle(3, 13, 10),
    candle(4, 12, 9), candle(5, 11, 7), candle(6, 12, 9), candle(7, 13, 10),
    candle(8, 16, 12), candle(9, 15, 11), candle(10, 14, 10), candle(11, 13, 6),
    candle(12, 14, 8), candle(13, 15, 9),
];

my $zz = Market::Indicators::InternalZigZag->compute(
    candles => $candles, atr_series => atr($candles, 1), max_visible_index => $#$candles,
    pivot_length => 2, min_leg_bars => 2, atr_multiplier => 1,
);
my $pivots = $zz->{pivots};
ok(@$pivots >= 3, 'detects confirmed internal structural pivots');
is_deeply([ map { $_->{type} } @$pivots ], [qw(HIGH LOW HIGH LOW)], 'pivots alternate HIGH and LOW');
is($pivots->[0]{index}, 2, 'first high uses the real candle index');
is($pivots->[0]{price}, $candles->[2]{high}, 'high pivot uses the candle high');
is($pivots->[1]{index}, 5, 'finds the swing low');
is($pivots->[1]{price}, $candles->[5]{low}, 'low pivot uses the candle low');
is($pivots->[0]{confirmed_at}, 4, 'pivot confirmation happens after the right window');
ok($zz->{replay_safe}, 'declares replay safety');

is($zz->{debug_pivots}[0]{type}, 'HIGH', 'debug output preserves pivot type');
is($zz->{debug_pivots}[0]{confirmed}, 1, 'debug output exposes confirmation state');

my $early = Market::Indicators::InternalZigZag->compute(
    candles => $candles, atr_series => atr($candles, 1), max_visible_index => 3,
    pivot_length => 2, min_leg_bars => 2, atr_multiplier => 1,
);
is(scalar @{$early->{pivots}}, 0, 'does not expose a pivot before its confirmation bars exist');

my $same_leg = [
    candle(0, 10, 8), candle(1, 12, 9), candle(2, 14, 11), candle(3, 13, 10),
    candle(4, 15, 12), candle(5, 14, 11), candle(6, 13, 7), candle(7, 12, 8),
];
my $same = Market::Indicators::InternalZigZag->compute(
    candles => $same_leg, atr_series => atr($same_leg, 1), max_visible_index => $#$same_leg,
    pivot_length => 1, min_leg_bars => 2, atr_multiplier => 1,
);
is($same->{pivots}[0]{type}, 'HIGH', 'starts with a high');
is($same->{pivots}[0]{index}, 4, 'replaces an endpoint with the more extreme same-leg high');
is($same->{pivots}[0]{price}, 15, 'keeps the most extreme same-leg price');

my $atr_filtered = Market::Indicators::InternalZigZag->compute(
    candles => $candles, atr_series => atr($candles, 10), max_visible_index => $#$candles,
    pivot_length => 2, min_leg_bars => 2, atr_multiplier => 2,
);
cmp_ok(scalar @{$atr_filtered->{pivots}}, '<', scalar @$pivots, 'ATR filter rejects insufficient moves');

ok(@{$zz->{segments}} >= 1, 'returns completed segments');
ok($zz->{active_segment}, 'keeps the latest segment as active');
is($zz->{active_segment}{start_index}, $pivots->[-2]{index}, 'active segment starts at penultimate pivot');
is($zz->{active_segment}{end_index}, $pivots->[-1]{index}, 'active segment ends at latest pivot');

my @extended = (@$candles, candle(14, 200, 1), candle(15, 201, 0));
my $prefix = Market::Indicators::InternalZigZag->compute(
    candles => $candles, atr_series => atr($candles, 1), max_visible_index => 10,
    pivot_length => 2, min_leg_bars => 2, atr_multiplier => 1,
);
my $same_prefix = Market::Indicators::InternalZigZag->compute(
    candles => \@extended, atr_series => atr(\@extended, 1), max_visible_index => 10,
    pivot_length => 2, min_leg_bars => 2, atr_multiplier => 1,
);
is_deeply($same_prefix->{pivots}, $prefix->{pivots}, 'future candles do not alter a historical cursor result');

eval {
    Market::Indicators::InternalZigZag->compute(
        candles => [ candle(0, 3, 4) ], pivot_length => 1,
    );
};
like($@, qr/high below low/, 'rejects invalid OHLC input instead of silently fabricating pivots');

my $market = Market::MarketData->new;
$market->add_candle({ %$_ }) for @$candles;
my $atr_indicator = Market::Indicators::ATR->new(2);
$atr_indicator->compute_all($market);
my $managed = Market::Indicators::InternalZigZag->new(
    pivot_length => 2, min_leg_bars => 2, atr_indicator => $atr_indicator,
);
$managed->compute_all($market);
is_deeply(
    [ map { { type => $_->{type}, index => $_->{index}, price => $_->{price}, confirmed_at => $_->{confirmed_at} } } @{$managed->get_pivots} ],
    [ map { { type => $_->{type}, index => $_->{index}, price => $_->{price}, confirmed_at => $_->{confirmed_at} } } @$pivots ],
    'IndicatorManager-compatible computation preserves the causal pivot contract',
);

done_testing();
