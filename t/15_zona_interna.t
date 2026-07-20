use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Indicators::InternalZigZag;
use Market::Indicators::ZonaInterna;
use Market::MarketData;

sub zigzag_hash {
    my (%args) = @_;
    return {
        segments => [
            { direction => 'bullish', start_index => 0, start_price => 100, end_index => 10, end_price => 110 },
            { direction => 'bearish', start_index => 10, start_price => 110, end_index => 20, end_price => 100 },
        ],
        active_segment => {
            direction => 'bullish', start_index => 20, start_price => 100,
            end_index => 30, end_price => $args{current_price},
        },
    };
}

my $zona = Market::Indicators::ZonaInterna->compute(
    zigzag => zigzag_hash(current_price => 120), max_visible_index => 30, mintick => 0.01,
);
is($zona->{direction}, 'bullish', 'detects direction from active ZigZag leg');
is($zona->{base_price}, 100, 'base is the previous ZigZag point');
is($zona->{diff}, 10, 'difference uses anchor minus previous point');
is($zona->{anchor_point}{index}, 10, 'line anchor is the third-last ZigZag point');
is(scalar @{$zona->{levels}}, 8, 'stops levels immediately after the defined crossing rule');
is($zona->{levels}[0]{ratio}, 0.618, 'first optional ratio is 0.618');
is($zona->{levels}[1]{ratio}, 0.786, 'second optional ratio is 0.786');
is($zona->{levels}[2]{ratio}, 1, 'extensions start at 1');
is(sprintf('%.2f', $zona->{levels}[0]{price}), '106.18', 'level price is base plus difference times ratio');
is($zona->{levels}[0]{text}, '0.618(106.18)', 'text has ratio and rounded price');
is($zona->{levels}[0]{x1_index}, 10, 'level starts at the anchor index');
is($zona->{levels}[0]{x2_index}, 30, 'level ends at current visible index');
ok($zona->{replay_safe}, 'declares replay safety');

my $early_stop = Market::Indicators::ZonaInterna->compute(
    zigzag => zigzag_hash(current_price => 105), max_visible_index => 30, mintick => 0.01,
);
is_deeply([map { $_->{ratio} } @{$early_stop->{levels}}], [0.618, 0.786, 1],
    'early stop preserves optional levels and the first extension');

my $without_optional = Market::Indicators::ZonaInterna->compute(
    zigzag => zigzag_hash(current_price => 120), max_visible_index => 30, mintick => 0.01,
    enable618 => 0, enable786 => 0,
);
is($without_optional->{levels}[0]{ratio}, 1, 'optional retracement levels can be disabled');

my $empty = Market::Indicators::ZonaInterna->compute(zigzag => { segments => [] }, max_visible_index => 10);
is(scalar @{$empty->{levels}}, 0, 'does not emit levels with fewer than three points');

my $future_points = {
    pivots => [
        { index => 1, price => 100, confirmed => 1, confirmed_at => 3 },
        { index => 5, price => 110, confirmed => 1, confirmed_at => 7 },
        { index => 9, price => 102, confirmed => 1, confirmed_at => 11 },
        { index => 15, price => 120, confirmed => 1, confirmed_at => 17 },
    ],
};
my $historical = Market::Indicators::ZonaInterna->compute(zigzag => $future_points, max_visible_index => 11);
is($historical->{direction}, 'bearish', 'uses only pivots known at the visible cursor');
is($historical->{current_point}{index}, 9, 'future confirmed pivot is excluded');

my $unconfirmed = Market::Indicators::ZonaInterna->compute(
    zigzag => { pivots => [
        { index => 1, price => 100, confirmed => 1, confirmed_at => 1 },
        { index => 2, price => 110, confirmed => 1, confirmed_at => 2 },
        { index => 3, price => 105, confirmed => 0, confirmed_at => 3 },
    ] },
    max_visible_index => 3,
);
is(scalar @{$unconfirmed->{levels}}, 0, 'unconfirmed pivots cannot create levels');

my @candles = map {
    my $close = 100 + ($_ % 4 == 0 ? 5 : $_ % 4 == 2 ? -5 : 0);
    { time => $_ * 60, open => $close, high => $close + 1, low => $close - 1, close => $close, volume => 1 }
} 0 .. 16;
my $zz = Market::Indicators::InternalZigZag->compute(
    candles => \@candles, atr_series => [(1) x @candles], pivot_length => 1, min_leg_bars => 1,
);
my $from_internal = Market::Indicators::ZonaInterna->compute(
    zigzag => $zz, max_visible_index => $#candles,
);
ok(ref($from_internal->{levels}) eq 'ARRAY', 'accepts InternalZigZag pivot output directly');

my $market = Market::MarketData->new;
$market->add_candle({ %$_ }) for @candles;
my $managed_zigzag = Market::Indicators::InternalZigZag->new(pivot_length => 1, min_leg_bars => 1);
$managed_zigzag->compute_all($market);
my $managed_zona = Market::Indicators::ZonaInterna->new(zigzag_indicator => $managed_zigzag, mintick => 0.01);
$managed_zona->compute_all($market);
my $expected_managed = Market::Indicators::ZonaInterna->compute(
    zigzag => $managed_zigzag->get_result, max_visible_index => $#candles, mintick => 0.01,
);
is_deeply($managed_zona->get_levels, $expected_managed->{levels},
    'Indicator-compatible ZonaInterna consumes InternalZigZag without an overlay');

my $empty_market = Market::MarketData->new;
my $empty_zona = Market::Indicators::ZonaInterna->new;
$empty_zona->compute_all($empty_market);
is_deeply($empty_zona->get_levels, [], 'an empty managed market produces an empty ZonaInterna result');

done_testing();
