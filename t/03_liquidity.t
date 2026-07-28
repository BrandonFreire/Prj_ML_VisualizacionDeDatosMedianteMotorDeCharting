use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", '.';
use Test::More;

use MarketTestUtil qw(make_market);
use Market::Indicators::Liquidity;

sub liquidity_candles {
    my ($scenario) = @_;
    my @rows = (
        [101,  99, 100], [102, 100, 101], [103, 101, 102],
        [110, 103, 104], [106, 102, 103], [105, 100, 101],
        [107, 101, 106], [108, 103, 107], [111, 105, 108],
        [109, 104, 106], [108, 103, 105], [107, 102, 104],
        [106, 101, 103], [105, 100, 102], [104,  99, 101],
    );

    if ($scenario eq 'grab') {
        $rows[8] = [111, 105, 111];
        $rows[9] = [109, 104, 109];
    }
    elsif ($scenario eq 'run') {
        $rows[8]  = [111, 105, 111];
        $rows[9]  = [112, 106, 111];
        $rows[10] = [113, 107, 111];
    }

    return [ map {
        my ($high, $low, $close) = @{ $rows[$_] };
        {
            time   => $_ * 60,
            open   => $close,
            high   => $high,
            low    => $low,
            close  => $close,
            volume => 10,
        }
    } 0 .. $#rows ];
}

sub liquidity_for {
    my ($scenario) = @_;
    my $market = make_market(liquidity_candles($scenario));
    my $liquidity = Market::Indicators::Liquidity->new(
        depth => 2,
        n_accept => 3,
        atr_period => 2,
    );
    $liquidity->compute_all($market);
    return $liquidity;
}

sub external_grab_liquidity {
    my @rows = (
        [101,  99, 100], [102, 100, 101], [103, 101, 102], [104, 102, 103],
        [105, 103, 104], [120, 104, 106], [110, 103, 105], [109, 102, 104],
        [108, 101, 103], [107, 100, 102], [111, 103, 106], [121, 105, 121],
        [119, 104, 119], [118, 103, 117], [117, 102, 116], [116, 101, 115],
        [115, 100, 114], [114,  99, 113], [113,  98, 112], [112,  97, 111],
    );
    my $market = make_market([ map {
        my ($high, $low, $close) = @{ $rows[$_] };
        {
            time => $_ * 60, open => $close, high => $high, low => $low,
            close => $close, volume => 10,
        }
    } 0 .. $#rows ]);
    my $liquidity = Market::Indicators::Liquidity->new(
        depth => 2,
        external_depth => 4,
        n_accept => 3,
        atr_period => 2,
    );
    $liquidity->compute_all($market);
    return $liquidity;
}

sub main_bsl {
    my ($levels) = @_;
    return (grep {
        ($_->{type} // '') eq 'BSL'
            && ($_->{index} // -1) == 3
            && ($_->{price} // 0) == 110
    } @$levels)[0];
}

my $sweep = liquidity_for('sweep');
my $sweep_level = main_bsl($sweep->get_levels());
ok($sweep_level, 'detecta el BSL confirmado por el swing high');
is($sweep_level->{classification}, 'SWEEP', 'mecha sobre BSL con cierre de rechazo es SWEEP');
is($sweep_level->{swept_at}, 8, 'SWEEP conserva la vela del barrido');
is($sweep_level->{resolved_at}, 8, 'SWEEP se resuelve en la misma vela');
is_deeply(
    $sweep_level->{state_path},
    [qw(DETECTED SWEPT RECLAIMED RESOLVED)],
    'SWEEP conserva la ruta de estados que explica su clasificacion',
);

my $grab = liquidity_for('grab');
my $grab_level = main_bsl($grab->get_levels());
is($grab_level->{classification}, 'GRAB', 'reclaim una vela después del quiebre es GRAB');
is($grab_level->{swept_at}, 8, 'GRAB conserva la vela que rompe el nivel');
is($grab_level->{resolved_at}, 9, 'GRAB se confirma al reclamar el nivel');
is_deeply(
    $grab_level->{state_path},
    [qw(DETECTED SWEPT RECLAIMED RESOLVED)],
    'GRAB conserva la ruta de estados de reclaim',
);

my $run = liquidity_for('run');
my $run_level = main_bsl($run->get_levels());
is($run_level->{classification}, 'RUN', 'tres cierres consecutivos fuera del BSL son RUN');
is($run_level->{resolved_at}, 10, 'RUN se confirma exactamente en el tercer cierre');
is_deeply(
    $run_level->{state_path},
    [qw(DETECTED SWEPT ACCEPTANCE RESOLVED)],
    'RUN conserva la ruta de estados de aceptacion',
);

my $pending_market = make_market([ @{ liquidity_candles('run') }[0 .. 8] ]);
my $pending = Market::Indicators::Liquidity->new(
    depth => 2, n_accept => 3, atr_period => 2,
);
$pending->compute_all($pending_market);
my $pending_level = main_bsl($pending->get_levels);
is($pending_level->{state}, 'SWEPT',
    'un cierre fuera al final del cursor mantiene el nivel pendiente');
is_deeply($pending_level->{state_path}, [qw(DETECTED SWEPT)],
    'el nivel pendiente expone solo los estados ya confirmados');
ok(!defined $pending_level->{classification} && !defined $pending_level->{resolved_at},
    'no adelanta SWEEP cuando las velas siguientes aún pueden confirmar GRAB o RUN');
ok(scalar(grep { ($_->{index} // -1) == 3 } @{$pending->get_active}),
    'el nivel pendiente sigue activo para el siguiente cálculo');

my $at_seven = main_bsl($sweep->get_levels_at(7));
ok($at_seven, 'el snapshot replay conserva el BSL conocido en la vela 7');
is($at_seven->{state}, 'DETECTED', 'el snapshot replay no conoce un Sweep futuro');
ok(!defined $at_seven->{classification}, 'el snapshot replay no expone una clasificación futura');
ok(
    scalar(grep { ($_->{index} // -1) == 3 } @{ $sweep->get_active_at(7) }),
    'el BSL sigue activo antes del barrido',
);
ok(
    !scalar(grep { ($_->{index} // -1) == 3 } @{ $sweep->get_resolved_at(7) }),
    'el BSL no aparece resuelto antes de la vela de Sweep',
);

my $external_grab = external_grab_liquidity();
my ($external_level) = grep {
    ($_->{type} // '') eq 'BSL' && ($_->{index} // -1) == 5
} @{ $external_grab->get_levels() };
is($external_level->{scope}, 'external', 'el pivote de ventana amplia se clasifica como externo');
is($external_level->{classification}, 'BIG_GRAB', 'un Grab sobre liquidez externa se distingue como BIG_GRAB');
is($external_level->{swept_at}, 11, 'BIG_GRAB conserva la vela de ruptura');
is($external_level->{resolved_at}, 12, 'BIG_GRAB se confirma al reclamar el nivel');

done_testing();
