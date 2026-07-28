use strict;
use warnings;

use Test::More;
use FindBin qw($Bin);
use lib "$Bin/..";

use Market::ML::GhostFeatureExtractor;

my $extractor = Market::ML::GhostFeatureExtractor->new(
    pip_size => 0.25, ghost_length => 2, external_depth => 4,
);

my $features = $extractor->feature_columns();
is scalar(@$features), 64, 'el esquema contiene 64 features antes del one-hot';
ok !grep({ /^(?:event_date|event_hour|event_minute|event_timestamp)$/ } @$features),
    'fecha, hora, minuto y timestamp no son features';
for my $tf (1, 10, 60) {
    for my $required (qw(
        ob_dist_pips fvg_dist_pips fib_dist_pips vwap_dist_pips
        vp_poc_dist_pips bos_choch_dist_pips eqh_eql_dist_pips
        sweep_grab_run_dist_pips supply_demand_dist_pips channel_dist_pips
    )) {
        ok grep({ $_ eq "tf${tf}_$required" } @$features),
            "$required existe en ${tf}m";
    }
}
ok grep({ $_ eq 'sr_4h_dist_pips' } @$features), 'incluye soporte/resistencia 4h';
ok grep({ $_ eq 'sr_d_dist_pips' } @$features), 'incluye soporte/resistencia diario';
ok grep({ $_ eq 'sr_w_dist_pips' } @$features), 'incluye soporte/resistencia semanal';
ok grep({ $_ eq 'atr_1m' } @$features), 'incluye ATR 1m';
ok grep({ $_ eq 'volume_1m' } @$features), 'incluye volumen 1m';
ok grep({ $_ eq 'volume_ema9_1m' } @$features), 'incluye EMA(9) de volumen 1m';

my @manual_events = (
    { event_timestamp => 1_000, _event_time => 1_000 },
    { event_timestamp => 1_180, _event_time => 1_180 },
    { event_timestamp => 1_240, _event_time => 1_240 },
    { event_timestamp => 1_600, _event_time => 1_600 },
);
$extractor->label_future_relocations(\@manual_events, 2_000);
is_deeply(
    [ @{$manual_events[0]}{qw(Y_3m Y_5m Y_10m Y_15m)} ],
    [1, 2, 3, 3],
    'los targets cuentan eventos en (t,t+N] usando minutos exactos',
);
is $manual_events[1]{Y_3m}, 1,
    'la ventana comienza despues del evento actual';
ok $manual_events[0]{complete}, 'marca completa si existe cobertura de 15 minutos';

my @bars;
my $base_time = 1_780_000_000;
for my $index (0 .. 359) {
    my $wave = sin($index / 4) * 8 + sin($index / 17) * 3;
    my $close = 20_000 + $wave + $index * 0.01;
    my $open = $close + sin($index) * 0.4;
    my $high = ($open > $close ? $open : $close) + 1.5 + ($index % 3) * 0.1;
    my $low = ($open < $close ? $open : $close) - 1.5 - ($index % 2) * 0.1;
    push @bars, {
        time => $base_time + $index * 60,
        datetime => 'synthetic',
        date => '2026-05-01',
        hour => int($index / 60),
        minute => $index % 60,
        timezone_offset => -5 * 3600,
        open => $open, high => $high, low => $low, close => $close,
        volume => 100 + ($index % 20),
    };
}

my $events = $extractor->detect_ghost_relocations(\@bars);
ok @$events > 20, 'Replay produce apariciones y movimientos del fantasma';
ok grep({ $_->{relocation} eq 'appearance' } @$events),
    'hay eventos de aparicion';
ok grep({ $_->{relocation} eq 'move' } @$events),
    'hay reubicaciones que representan rastros';
ok !grep({ $_->{event_index} < $_->{ghost_index} } @$events),
    'ningun fantasma usa un indice futuro';

my $result = $extractor->extract(bars => \@bars);
ok @{ $result->{rows} } > 10, 'extrae filas completas de la serie sintetica';
ok !grep({ !defined $_->{ghost_hlc3} } @{ $result->{rows} }),
    'HLC3 de la vela donde está el fantasma está disponible en todas las filas';
ok !grep({
        my $bar = $bars[ $_->{ghost_index} ];
        my $expected = ($bar->{high} + $bar->{low} + $bar->{close}) / 3;
        abs($_->{ghost_hlc3} - $expected) > 1e-9;
    } @{ $result->{rows} }),
    'las distancias usan la vela del fantasma y no la vela de confirmación';
ok !grep({ !defined $_->{atr_1m} } @{ $result->{rows} }),
    'ATR causal disponible en todas las filas';
ok !grep({ !defined $_->{volume_ema9_1m} } @{ $result->{rows} }),
    'EMA de volumen disponible en todas las filas';
ok !grep({
        !($_->{Y_3m} <= $_->{Y_5m}
        && $_->{Y_5m} <= $_->{Y_10m}
        && $_->{Y_10m} <= $_->{Y_15m})
    } @{ $result->{rows} }),
    'targets acumulativos monotonos';

my @prefix_bars = @bars[0 .. 239];
my $prefix_result = Market::ML::GhostFeatureExtractor->new(
    pip_size => 0.25, ghost_length => 2, external_depth => 4,
)->extract(bars => \@prefix_bars);
my %full_by_id = map { $_->{event_id} => $_ } @{ $result->{rows} };
my @comparison_columns = (
    @{ $result->{feature_columns} },
    @{ $result->{target_columns} },
);
my $prefix_invariant = 1;
for my $prefix_row (@{ $prefix_result->{rows} }) {
    my $full_row = $full_by_id{ $prefix_row->{event_id} };
    if (!$full_row) {
        $prefix_invariant = 0;
        last;
    }
    for my $column (@comparison_columns) {
        my $left = defined($prefix_row->{$column}) ? $prefix_row->{$column} : '__NA__';
        my $right = defined($full_row->{$column}) ? $full_row->{$column} : '__NA__';
        if ("$left" ne "$right") {
            $prefix_invariant = 0;
            last;
        }
    }
    last unless $prefix_invariant;
}
ok $prefix_invariant,
    'un prefijo Replay produce las mismas features y etiquetas que el historial completo';

done_testing;
