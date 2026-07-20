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
is($missed_high[0]{index}, 7, 'la reversión high omitida guarda el extremo correcto');
is($missed_low[0]{index}, 25, 'la reversión low omitida guarda el extremo correcto');
ok($missed_high[0]{confirmed_at} > $missed_high[0]{index},
    'un missed pivot se publica después de estar confirmado');
is(scalar(grep { $_->{active} } @{ $missed->{reversal_levels} }), 1,
    'mantiene un único nivel de reversión omitida activo');
ok($missed->{provisional_pivot}, 'expone el extremo provisional aún no confirmado');
is($missed->{provisional_pivot}{index}, 29,
    'el provisional busca el extremo posterior al último pivot regular');
ok($missed->{replay_safe}, 'el cálculo completo declara seguridad para Replay');

my $disabled = Market::Indicators::PivotMissedReversal->compute(
    candles => \@missed_candles, length => 2, show_missed => 0,
);
is(scalar @{ $disabled->{missed_pivots} }, 0, 'show_missed desactiva los pivotes omitidos');
is(scalar @{ $disabled->{reversal_levels} }, 0, 'show_missed también desactiva sus niveles');

done_testing();
