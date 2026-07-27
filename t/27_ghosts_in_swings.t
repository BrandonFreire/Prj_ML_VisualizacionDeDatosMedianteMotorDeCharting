use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Indicators::GhostsInSwings;
use Market::ML::GhostTargets;
use Market::Overlays::GhostsInSwings;
use Market::IndicatorManager;
use Market::MarketData;

sub candle {
    my ($i, $high, $low) = @_;
    return {
        time => $i * 60, open => ($high + $low) / 2,
        high => $high, low => $low, close => ($high + $low) / 2, volume => 1,
    };
}

# length=1 permite comprobar la máquina de estados en una serie corta. El
# valor de producción sigue siendo 50 y se valida más abajo.
my @candles = (
    candle(0, 10, 5), candle(1, 12, 6), candle(2, 11, 7),
    candle(3, 10, 4), candle(4, 9, 3), candle(5, 11, 5),
    candle(6, 14, 7), candle(7, 13, 8), candle(8, 12, 6),
);
my $ghosts = Market::Indicators::GhostsInSwings->new(length => 1);
my $result = $ghosts->compute(candles => \@candles);

is(Market::Indicators::GhostsInSwings->new->get_result->{pivot_length}, 50,
    'el Pivot Length de producción es 50');
is_deeply(
    [ map { [ $_->{occurrence_index}, $_->{type}, $_->{relocation} ] }
      @{ $result->{relocations} } ],
    [
        [2, 'low',  'appearance'], [3, 'low',  'move'],
        [4, 'low',  'move'],       [5, 'high', 'appearance'],
        [6, 'high', 'move'],       [7, 'low',  'appearance'],
        [8, 'low',  'move'],
    ],
    'emite aparición y relocalizaciones en el extremo opuesto al último pivote',
);
is_deeply(
    [ map { [ $_->{occurrence_index}, $_->{label} ] } @{ $result->{trails} } ],
    [ [3, '1'], [4, '1'], [6, '1'], [8, '1'] ],
    'solo las reubicaciones reales dejan un rastro con etiqueta 1',
);

my $snapshot = $ghosts->snapshot_at(4);
is_deeply([ map { $_->{occurrence_index} } @{ $snapshot->{trails} } ], [3, 4],
    'Replay en el cursor no conoce rastros futuros');
is($snapshot->{active_ghost}{occurrence_index}, 4,
    'el fantasma activo coincide con la última reubicación causal');

my $prefix = Market::Indicators::GhostsInSwings->new(length => 1);
my $prefix_result = $prefix->compute(candles => [ @candles[0 .. 4] ]);
is_deeply($prefix_result->{trails}, $snapshot->{trails},
    'recalcular sólo el prefijo da exactamente los rastros de Replay');

my $market = Market::MarketData->new;
$market->add_candle($_) for @candles;
$market->build_timeframes;
my $managed_ghosts = Market::Indicators::GhostsInSwings->new(length => 1);
my $manager = Market::IndicatorManager->new;
$manager->register('GhostsInSwings', $managed_ghosts);
$manager->compute_all($market);
is($managed_ghosts->get_max_index, 8,
    'IndicatorManager calcula GhostsInSwings en la serie 1m');
$market->set_timeframe('5');
$manager->reset_all;
$manager->compute_all($market);
is($managed_ghosts->get_max_index, $market->last_index,
    'el ciclo de vida del manager recompone el indicador al cambiar timeframe');

my $targets = Market::ML::GhostTargets->new->compute(
    relocations => [
        { id => 'r10', occurrence_index => 10, occurrence_time => 600,
          ghost_index => 10, ghost_time => 600, price => 100, type => 'low', relocation => 'move' },
        { id => 'r20', occurrence_index => 20, occurrence_time => 1200,
          ghost_index => 20, ghost_time => 1200, price => 90, type => 'low', relocation => 'move' },
    ],
    trails => [ map { { occurrence_index => $_, label => '1' } } (11, 12, 13, 15, 16, 20, 25) ],
    last_index => 30,
);
is_deeply(
    [ @{$targets->[0]}{qw(Y_3m Y_5m Y_10m Y_15m)} ], [3, 4, 6, 7],
    'las ventanas Y cuentan rastros desde la vela inmediatamente siguiente',
);
ok($targets->[0]{complete}, 'un evento con 15 velas futuras queda listo para entrenamiento');
ok(!$targets->[1]{complete}, 'un evento cercano al final se marca incompleto');
ok(!defined $targets->[1]{Y_15m}, 'no inventa un target sin horizonte completo');

{
    package GhostCanvas;
    sub new { bless { calls => [] }, shift }
    sub delete { push @{ $_[0]{calls} }, ['delete', $_[1]] }
    sub createText { push @{ $_[0]{calls} }, ['createText', @_[1 .. $#_]] }
    sub tagged {
        my ($self, $tag) = @_;
        return [ grep {
            my @args = @$_;
            my ($at) = grep { $args[$_] eq '-tags' } 0 .. $#args;
            defined($at) && ref($args[$at + 1]) eq 'ARRAY'
                && grep { $_ eq $tag } @{ $args[$at + 1] };
        } @{ $self->{calls} } ];
    }
}
{
    package GhostScale;
    sub new { bless {}, shift }
    sub index_to_center_x { $_[1] * 10 }
    sub value_to_y { 200 - $_[1] }
}
{
    package GhostMarket;
    sub new { bless { current_tf => $_[1] }, $_[0] }
}

my $canvas = GhostCanvas->new;
my $overlay = Market::Overlays::GhostsInSwings->new(
    indicator => $ghosts,
    market => GhostMarket->new('1'),
    visibility => { ghosts_enabled => 1, show_ghost_active => 1, show_ghost_trails => 1 },
);
$overlay->render($canvas, 0, 8, GhostScale->new, 4);
is(scalar @{ $canvas->tagged('ghosts_trail') }, 2,
    'el overlay de Replay sólo dibuja los rastros conocidos en cursor 4');
is(scalar @{ $canvas->tagged('ghosts_active') }, 1,
    'el overlay dibuja un único fantasma activo');

$canvas = GhostCanvas->new;
my $hidden_overlay = Market::Overlays::GhostsInSwings->new(
    indicator => $ghosts,
    market => GhostMarket->new('5'),
    visibility => { ghosts_enabled => 1, show_ghost_active => 1, show_ghost_trails => 1 },
);
$hidden_overlay->render($canvas, 0, 8, GhostScale->new, 8);
is(scalar @{ $canvas->tagged('ghosts_overlay') }, 0,
    'el overlay se inhibe fuera de la temporalidad 1m');

done_testing();
