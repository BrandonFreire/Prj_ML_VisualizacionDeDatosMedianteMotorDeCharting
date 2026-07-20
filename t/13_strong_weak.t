use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Indicators::SMC_Structures;

sub candle {
    my ($index, $high, $low) = @_;
    return {
        time => $index * 60, open => ($high + $low) / 2,
        high => $high, low => $low, close => ($high + $low) / 2, volume => 100,
    };
}

my $candles = [
    candle(0, 8, 6), candle(1, 10, 6), candle(2, 9, 6),
    candle(3, 9, 6), candle(4, 9, 5), candle(5, 15, 5.5),
    candle(6, 11, 5.2), candle(7, 10, 4), candle(8, 10, 4),
    candle(9, 12, 4.5), candle(10, 12, 4),
];
my $pivots = [
    { id => 'H_OLD', kind => 'high', scope => 'external', index => 1,
      time => $candles->[1]{time}, price => 10, confirmed_at => 3 },
    { id => 'L_CURRENT', kind => 'low', scope => 'external', index => 4,
      time => $candles->[4]{time}, price => 5, confirmed_at => 6 },
    { id => 'H_CURRENT', kind => 'high', scope => 'external', index => 6,
      time => $candles->[6]{time}, price => 11, confirmed_at => 8 },
];
my $bullish = { id => 'BOS_UP', type => 'BOS', scope => 'external', direction => 'bull', confirmed_at => 5 };
my $bearish = { id => 'CHOCH_DOWN', type => 'CHOCH', scope => 'external', direction => 'bear', confirmed_at => 9 };

my $on_confirmation = Market::Indicators::SMC_Structures::_build_trailing_extremes(
    $candles, $pivots, [$bullish, $bearish], 8,
);
is($on_confirmation->{source_high_pivot_id}, 'H_OLD',
    'un swing externo no aparece antes de que cierre su vela de confirmación');
is($on_confirmation->{structural_bias}, 'bullish',
    'un evento estructural futuro no contamina el contexto actual');

my $state = Market::Indicators::SMC_Structures::_build_trailing_extremes(
    $candles, $pivots, [$bullish, $bearish], 10,
);
is($state->{source_high_pivot_id}, 'H_CURRENT', 'usa el último swing high externo confirmado');
is($state->{source_low_pivot_id}, 'L_CURRENT', 'usa el último swing low externo confirmado');
is($state->{top}, 12, 'el extremo alto sigue el máximo posterior al reset');
is($state->{bottom}, 4, 'el extremo bajo sigue el mínimo posterior al reset');
is($state->{last_top_index}, 10, 'un empate alto conserva el contacto más reciente');
is($state->{last_bottom_index}, 10, 'un empate bajo conserva el contacto más reciente');
is($state->{structural_bias}, 'bearish', 'el último BOS/CHoCH externo confirmado define el sesgo');
is($state->{high_classification}, 'strong_high', 'sesgo bajista clasifica Strong High');
is($state->{low_classification}, 'weak_low', 'sesgo bajista clasifica Weak Low');
is($state->{source_structure_event_id}, 'CHOCH_DOWN', 'enlaza la clasificación al evento causal');
ok($state->{replay_safe}, 'el estado actual declara seguridad para Replay');

my $bull_state = Market::Indicators::SMC_Structures::_build_trailing_extremes(
    $candles, $pivots, [$bullish], 10,
);
is($bull_state->{high_classification}, 'weak_high', 'sesgo alcista deja el máximo como débil');
is($bull_state->{low_classification}, 'strong_low', 'sesgo alcista marca el mínimo como fuerte');

done_testing();
