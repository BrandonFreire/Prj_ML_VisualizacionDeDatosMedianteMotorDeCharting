use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Indicators::PivotMissedReversal;

sub c {
    my ($i, $high, $low) = @_;
    return {
        time => $i * 60, open => ($high + $low) / 2,
        high => $high, low => $low, close => ($high + $low) / 2, volume => 1,
    };
}

my $reference_defaults = Market::Indicators::PivotMissedReversal->new;
is($reference_defaults->{length}, 50,
    'usa Pivot Length 50, igual que Ghosts_in_swings.txt adjunto');

my $trace_fixture = [
    c(0, 10, 5),
    c(1, 11, 6),  # aparición inicial HIGH
    c(2, 15, 7),  # nuevo extremo HIGH
    c(3, 12, 8),  # PH(2) confirmado: nueva ancla, fantasma LOW
    c(4, 11, 7),  # nuevo extremo LOW
    c(5, 13, 7),  # empate: mueve icono, pero no sale del rango
    c(6, 14, 6),  # nuevo extremo LOW
];
my $trace_result = Market::Indicators::PivotMissedReversal->compute(
    candles => $trace_fixture, length => 1,
);
is_deeply(
    [
        map {
            [ $_->{event_index}, $_->{ghost_index}, $_->{ghost_type},
              $_->{relocation}, $_->{ghost_price} ]
        } @{ $trace_result->{trace_events} }
    ],
    [
        [1, 1, 'high', 'appearance', 11],
        [2, 2, 'high', 'move',       15],
        [3, 3, 'low',  'appearance', 8],
        [4, 4, 'low',  'move',       7],
        [6, 6, 'low',  'move',       6],
    ],
    'Replay replica apariciones y deja un solo rastro por extremo nuevo',
);
ok(!grep({ $_->{event_index} == 5 } @{ $trace_result->{trace_events} }),
    'un empate de precio no se etiqueta como movimiento fuera del rango');
is($trace_result->{current_ghost}{index}, 6,
    'expone el fantasma vivo en el extremo del último cursor');

my $regular_candles = [
    c(0, 10, 5), c(1, 11, 6), c(2, 15, 7), c(3, 12, 6),
    c(4, 11, 4), c(5, 10, 6), c(6, 14, 7), c(7, 13, 6), c(8, 12, 5),
];
my $detector = Market::Indicators::PivotMissedReversal->new(length => 2);
my $regular = $detector->compute(candles => $regular_candles);
is($regular->{regular_pivots}[0]{type}, 'high', 'detecta un pivot high regular');
is($regular->{regular_pivots}[0]{index}, 2, 'el pivot high conserva la vela extrema');
is($regular->{regular_pivots}[0]{confirmed_at}, 4,
    'el pivot high solo aparece dos velas después');
is($regular->{regular_pivots}[0]{label}, "\x{25BC}",
    'el pivot high conserva la marca visual del indicador de referencia');
is($regular->{regular_pivots}[1]{type}, 'low', 'detecta el pivot low posterior');
is($regular->{regular_pivots}[1]{index}, 4, 'el pivot low conserva su índice real');
is($regular->{regular_pivots}[1]{confirmed_at}, 6,
    'el pivot low también espera la confirmación configurada');

my $before = $detector->snapshot_at(3);
is(scalar @{ $before->{regular_pivots} }, 0,
    'el snapshot no adelanta el pivot antes de su confirmación');
my $at_confirmation = $detector->snapshot_at(4);
is(scalar @{ $at_confirmation->{regular_pivots} }, 1,
    'el snapshot incorpora el pivot justo al confirmarse');
is(scalar @{ $detector->get_regular_pivots() }, 3,
    'snapshot_at no muta el cálculo completo del indicador');

my @pairs = (
    [59,51], [54,48], [49,45], [50,49], [57,53], [57,54],
    [62,55], [66,54], [61,55], [65,60], [64,57], [63,57],
    [66,60], [62,56], [62,55], [58,52], [61,55], [61,58],
    [58,53], [61,54], [63,56], [62,58], [58,54], [58,53],
    [58,54], [60,52], [57,46], [50,49], [55,46], [52,45], [54,46],
);
my @missed_candles = map { c($_, @{ $pairs[$_] }) } 0 .. $#pairs;
my $missed = Market::Indicators::PivotMissedReversal->compute(
    candles => \@missed_candles, length => 2,
);
my @missed_high = grep { $_->{type} eq 'high' } @{ $missed->{missed_pivots} };
my @missed_low  = grep { $_->{type} eq 'low'  } @{ $missed->{missed_pivots} };
ok(@missed_high, 'detecta al menos una reversión high omitida');
ok(@missed_low, 'detecta al menos una reversión low omitida');
ok(scalar(grep { $_->{index} == 16 } @missed_high),
    'la reversión high omitida usa la secuencia alternante tras normalizar una vela exterior');
is($missed_low[0]{index}, 8,
    'la reversión low omitida conserva el extremo de la secuencia causal normalizada');
ok($missed_high[0]{confirmed_at} > $missed_high[0]{index},
    'un missed pivot se publica después de estar confirmado');
is(scalar(grep { $_->{active} } @{ $missed->{reversal_levels} }), 1,
    'mantiene un único nivel de reversión omitida activo');
ok($missed->{provisional_pivot}, 'expone el extremo provisional aún no confirmado');
is($missed->{provisional_pivot}{index}, 29,
    'el provisional busca el extremo posterior al último pivot regular');
ok($missed->{replay_safe}, 'el cálculo completo declara seguridad para Replay');
is($missed->{missed_pivots}[0]{label}, "\x{1F47B}",
    'los pivotes omitidos exponen la marca fantasma en su contrato');

my $initial_low = Market::Indicators::PivotMissedReversal->compute(
    candles => [ c(0, 10, 6), c(1, 8, 4), c(2, 9, 5) ],
    length => 1,
);
is_deeply(
    [ map { [ $_->{type}, $_->{index}, $_->{confirmed_at} ] }
      @{ $initial_low->{missed_pivots} } ],
    [ [ 'high', 0, 2 ] ],
    'conserva el primer máximo omitido antes del primer pivot low confirmado',
);

my $disabled = Market::Indicators::PivotMissedReversal->compute(
    candles => \@missed_candles, length => 2, show_missed => 0,
);
is(scalar @{ $disabled->{missed_pivots} }, 0, 'show_missed desactiva los pivotes omitidos');
is(scalar @{ $disabled->{reversal_levels} }, 0, 'show_missed también desactiva sus niveles');

my $outside_without_context = [
    c(0, 9, 1), c(1, 10, 0), c(2, 9, 1), c(3, 9, 1),
];
my $outside_first = Market::Indicators::PivotMissedReversal->compute(
    candles => $outside_without_context, length => 1,
);
is(scalar @{ $outside_first->{regular_pivots} }, 0,
    'una vela exterior sin pivote previo no inventa dirección');
is($outside_first->{ambiguous_pivots}[0]{resolution}, 'skipped_without_context',
    'expone la resolución causal de la vela ambigua');

my $after_high = Market::Indicators::PivotMissedReversal->compute(
    candles => [
        c(0, 8, 4), c(1, 10, 6), c(2, 9, 5),
        c(3, 20, 0), c(4, 9, 5), c(5, 8, 4),
    ], length => 1,
);
is_deeply([ map { [ $_->{type}, $_->{index} ] } @{ $after_high->{regular_pivots} } ],
    [ ['high', 1], ['low', 3] ],
    'una vela exterior posterior a HIGH se resuelve como LOW para conservar alternancia');
is($after_high->{ambiguous_pivots}[0]{resolution}, 'low_after_high',
    'la auditoría conserva la razón de la resolución ambigua');

my $after_low = Market::Indicators::PivotMissedReversal->compute(
    candles => [
        c(0, 10, 6), c(1, 8, 4), c(2, 9, 5),
        c(3, 20, 0), c(4, 9, 5), c(5, 10, 6),
    ], length => 1,
);
is_deeply([ map { [ $_->{type}, $_->{index} ] } @{ $after_low->{regular_pivots} } ],
    [ ['low', 1], ['high', 3] ],
    'una vela exterior posterior a LOW se resuelve como HIGH para conservar alternancia');

my ($active_level) = grep { $_->{active} } @{ $missed->{reversal_levels} };
is($active_level->{end_index}, $#missed_candles,
    'el nivel de reversión activo se extiende hasta el cursor visible');
my $stateful = Market::Indicators::PivotMissedReversal->new(length => 2);
$stateful->compute(candles => \@missed_candles);
my ($getter_active) = grep { $_->{active} } @{ $stateful->get_reversal_levels };
is($getter_active->{end_index}, $#missed_candles,
    'el getter conserva la misma extensión visible que el resultado de compute');
ok($missed->{missed_pivots}[0]{confirmed}
    && defined $missed->{missed_pivots}[0]{pivotTime},
    'los missed pivots exponen contrato confirmado apto para consumidores analíticos');
my $provisional_at_28 = $stateful->get_provisional_pivot_at(28);
ok($provisional_at_28 && $provisional_at_28->{provisional},
    'expone el fantasma provisional para un cursor histórico');
ok($provisional_at_28->{index} <= 28,
    'el provisional histórico nunca rebasa el cursor solicitado');

eval {
    Market::Indicators::PivotMissedReversal->compute(
        candles => [ { time => 0, high => 'invalido', low => 1 } ], length => 1,
    );
};
like($@, qr/high numerico finito/, 'rechaza precios no numéricos sin coercionarlos a cero');

done_testing();
