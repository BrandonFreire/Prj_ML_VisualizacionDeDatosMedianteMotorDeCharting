use strict;
use warnings;

use Test::More;
use lib '.';

use Market::MarketData;
use Market::Indicators::AnchoredVWAP;

sub candle {
    my ($index, $open, $high, $low, $close, $volume) = @_;
    return {
        time => $index * 60, open => $open, high => $high, low => $low,
        close => $close, volume => $volume,
    };
}

my @candles = (
    candle(0, 10, 12,  9, 11, 100),
    candle(1, 11, 15, 10, 14, 200),
    candle(2, 14, 16, 13, 15, 300),
    candle(3, 15, 17, 12, 13, 400),
    candle(4, 13, 14,  8,  9, 500),
);
my $high = {
    id => 'missed_high_1_2', kind => 'missedPivot', confirmed => 1,
    type => 'high', pivotType => 'high', index => 1, price => 15,
    pivotTime => $candles[1]{time}, confirmationIndex => 2,
    confirmationTime => $candles[2]{time}, confirmed_at => 2,
};
my $low = {
    id => 'missed_low_3_4', kind => 'missedPivot', confirmed => 1,
    type => 'low', pivotType => 'low', index => 3, price => 8,
    pivotTime => $candles[3]{time}, confirmationIndex => 4,
    confirmationTime => $candles[4]{time}, confirmed_at => 4,
};

my $before = Market::Indicators::AnchoredVWAP->compute_missed_pivot_auto(
    candles => \@candles, max_visible_index => 1, missed_pivot_events => [$high],
);
ok(!$before->{visible}, 'no crea AVWAP antes de la vela de confirmación');
is($before->{reason}, 'no_confirmed_missed_pivot', 'expone que el evento aún no es visible');

my $one = Market::Indicators::AnchoredVWAP->compute_missed_pivot_auto(
    candles => \@candles, max_visible_index => 2, missed_pivot_events => [$high],
);
ok($one->{visible}, 'un missed pivot confirmado crea AVWAP automático');
is($one->{line}{anchor_idx}, 1, 'se ancla en la vela extrema, no en la confirmación');
is($one->{line}{anchor_source}, 'missed_pivot_auto', 'identifica el origen analítico');
is($one->{line}{pivot_type}, 'high', 'conserva el tipo de pivote');
is($one->{line}{confirmation_index}, 2, 'conserva la barrera temporal de confirmación');
my $hlc3_1 = (15 + 10 + 14) / 3;
cmp_ok(abs($one->{line}{values}[1] - $hlc3_1), '<', 1e-10,
    'el primer valor usa HLC3 de la vela ancla');
my $hlc3_2 = (16 + 13 + 15) / 3;
my $expected = ($hlc3_1 * 200 + $hlc3_2 * 300) / 500;
cmp_ok(abs($one->{line}{values}[2] - $expected), '<', 1e-10,
    'el VWAP pondera precios por volumen desde el ancla');
ok($one->{replay_safe}, 'declara que no usa eventos ni velas futuros');

my $latest = Market::Indicators::AnchoredVWAP->compute_missed_pivot_auto(
    candles => \@candles, max_visible_index => 4,
    missed_pivot_events => [$high, $high, $low],
);
is($latest->{line}{source_event_id}, 'missed_low_3_4',
    'solo mantiene el missed pivot confirmado más reciente');
is($latest->{line}{anchor_idx}, 3, 'reemplaza el ancla automática anterior');

my $provisional = { %$low, id => 'temporary', kind => 'provisionalPivot', confirmed => 0 };
my $ignore_provisional = Market::Indicators::AnchoredVWAP->compute_missed_pivot_auto(
    candles => \@candles, max_visible_index => 4, missed_pivot_events => [$provisional],
);
ok(!$ignore_provisional->{visible}, 'un pivote provisional nunca crea AVWAP automático');

my @extended = (@candles, candle(5, 50, 51, 49, 50, 1));
my $prefix = Market::Indicators::AnchoredVWAP->compute_missed_pivot_auto(
    candles => \@candles, max_visible_index => 2, missed_pivot_events => [$high, $low],
);
my $same_prefix = Market::Indicators::AnchoredVWAP->compute_missed_pivot_auto(
    candles => \@extended, max_visible_index => 2, missed_pivot_events => [$high, $low],
);
is_deeply($same_prefix->{line}{values}, $prefix->{line}{values},
    'datos posteriores al cursor no alteran valores ya calculados');

{
    package TestPivotMissed;
    sub new { bless { events => $_[1] }, $_[0] }
    sub get_missed_pivots { return $_[0]->{events} }
}
my $market = Market::MarketData->new;
$market->add_candle($_) for @candles;
my $indicator = Market::Indicators::AnchoredVWAP->new;
$indicator->set_pivot_missed_indicator(TestPivotMissed->new([$high, $low]));
$indicator->compute_all($market);
my @auto_lines = grep { ($_->{anchor_source} // '') eq 'missed_pivot_auto' }
    @{ $indicator->get_vwap_lines() };
is(scalar @auto_lines, 1, 'compute_all integra exactamente una instancia automática');
is($auto_lines[0]{anchor_idx}, 3, 'la integración consume el último evento del indicador de pivotes');
ok($indicator->get_auto_missed_result->{visible}, 'conserva el resultado automático auditable');
my @historical_auto = grep { ($_->{anchor_source} // '') eq 'missed_pivot_auto' }
    @{ $indicator->get_vwap_lines_at(2) };
is(scalar @historical_auto, 1,
    'Replay reconstruye exactamente una instancia automática histórica');
is($historical_auto[0]{source_event_id}, 'missed_high_1_2',
    'Replay usa el último missed pivot confirmado en ese cursor, no el futuro');
is($historical_auto[0]{end_idx}, 2,
    'la línea automática histórica termina en la barrera de Replay');
is($indicator->get_vwap_lines->[0]{source_event_id}, 'missed_low_3_4',
    'consultar un cursor histórico no muta el AVWAP completo');

eval { $indicator->get_vwap_lines_at('invalido') };
like($@, qr/max_visible_index/, 'rechaza un cursor AVWAP inválido');

my $large_market = Market::MarketData->new;
$large_market->add_candle(candle(0, 1e12, 1e12,     1e12,     1e12,     1));
$large_market->add_candle(candle(1, 1e12, 1e12 + 1, 1e12 + 1, 1e12 + 1, 1));
my $stable = Market::Indicators::AnchoredVWAP->new;
$stable->add_manual_anchor(0);
$stable->compute_all($large_market);
cmp_ok(abs($stable->get_vwap_lines->[0]{std_dev}[1] - 0.5), '<', 1e-10,
    'la desviación VWAP usa varianza estable incluso con precios de gran magnitud');

my $bad_price = Market::Indicators::AnchoredVWAP->compute_missed_pivot_auto(
    candles => \@candles, max_visible_index => 2,
    missed_pivot_events => [ { %$high, price => 'invalido' } ],
);
ok(!$bad_price->{visible}, 'ignora eventos missed pivot con precio no numérico');

my $compact = Market::Indicators::AnchoredVWAP->new(anchor_mode => 'multipivot');
$compact->add_manual_anchor(1);
$compact->add_manual_anchor(3);
$compact->compute_all($market);
my $stored_points = 0;
$stored_points += scalar @{ $_->{values} } for @{ $compact->get_vwap_lines };
cmp_ok($stored_points, '<=', scalar(@candles),
    'multipivot almacena cada tramo una sola vez en vez de reservar toda la historia por ancla');
ok(!(grep { ($_->{values_offset} // -1) != $_->{anchor_idx} } @{ $compact->get_vwap_lines }),
    'cada tramo compacto declara el desplazamiento de sus valores');

{
    package TestGhostSwingPivot;
    sub new { bless {}, $_[0] }
    sub get_missed_pivots { return [] }
    sub get_ghost_anchors {
        return [
            { confirmed_at => 0, index => 0, os => 0, type => 'initial' },
            { confirmed_at => 2, index => 1, os => 1,
              type => 'high', price => 15 },
        ];
    }
    sub get_provisional_pivot_at {
        my ($self, $cursor) = @_;
        return {
            index => $cursor, price => 8, type => 'low',
            from_index => 1, from_price => 15,
        };
    }
}

my $ghost_swing = Market::Indicators::AnchoredVWAP->new(
    ghost_swing_enabled => 1,
);
$ghost_swing->set_pivot_missed_indicator(TestGhostSwingPivot->new);
$ghost_swing->compute_all($market);
my @swing_lines = grep {
    ($_->{anchor_source} // '') =~ /^ghost_(?:regular_pivot|live)$/
} @{ $ghost_swing->get_vwap_lines };
is(scalar @swing_lines, 2,
    'integra los AVWAP del último swing regular y del fantasma vivo');
is($swing_lines[0]{anchor_idx}, 1,
    'el Swing VWAP se ancla al pivote regular confirmado');
is($swing_lines[1]{anchor_idx}, 4,
    'el Ghost VWAP se ancla a la vela actual del fantasma');
my @swing_at_2 = grep {
    ($_->{anchor_source} // '') =~ /^ghost_(?:regular_pivot|live)$/
} @{ $ghost_swing->get_vwap_lines_at(2) };
is_deeply([ map { $_->{anchor_idx} } @swing_at_2 ], [1, 2],
    'Replay reconstruye ambas anclas sólo con el cursor solicitado');

done_testing();
