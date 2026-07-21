use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", '.';
use Test::More;

use Market::MarketData;
use Market::Indicators::SMC_Structures;

sub smc_market {
    my $last_index = shift;
    my @rows = (
        [101,  99, 100, 100], [102, 100, 101, 101], [104, 101, 103, 101],
        [110, 103, 104, 104], [106, 102, 103, 103], [105, 100, 101, 101],
        [107, 101, 106, 106], [108, 103, 107, 107], [112, 104, 111, 111],
        [109, 104, 106, 106], [108, 103, 105, 105], [107, 102, 104, 104],
        [106, 101, 103, 103], [105, 100, 102, 102], [104,  99, 101, 101],
    );
    $last_index = $#rows unless defined $last_index;

    my $market = Market::MarketData->new;
    for my $i (0 .. $last_index) {
        my ($high, $low, $close, $open) = @{ $rows[$i] };
        $market->add_candle({
            time   => $i * 60,
            open   => $open,
            high   => $high,
            low    => $low,
            close  => $close,
            volume => 10,
        });
    }
    return $market;
}

sub smc_for {
    my ($last_index) = @_;
    my $smc = Market::Indicators::SMC_Structures->new(
        depth => 2,
        external_depth => 4,
    );
    $smc->compute_all(smc_market($last_index));
    return $smc;
}

my $smc = smc_for();
my ($bos) = grep {
    ($_->{direction} // '') eq 'bull' && ($_->{from} // -1) == 3
} @{ $smc->get_bos_events() };

ok($bos, 'detecta BOS alcista al cerrar sobre el swing high confirmado');
is($bos->{index}, 8, 'BOS ocurre en la vela que cierra sobre el nivel');
is($bos->{level}, 110, 'BOS conserva el precio exacto del swing roto');
is($bos->{pivot_confirmed_at}, 5, 'BOS no usa el pivot antes de su confirmación');
is($bos->{scope}, 'internal', 'BOS mantiene el scope interno del swing');

my ($ob) = grep {
    ($_->{direction} // '') eq 'bull' && ($_->{triggered_by} // -1) == 8
} @{ $smc->get_ob_zones() };
ok($ob, 'un BOS alcista crea su Order Block asociado');
is($ob->{index}, 5, 'Order Block usa el parsedLow extremo entre pivote y ruptura');
is($ob->{top}, 105, 'Order Block conserva el high completo de la vela fuente');
is($ob->{bottom}, 100, 'Order Block conserva el low completo de la vela fuente');
ok($ob->{relevant}, 'el Order Block asociado a un desplazamiento fuerte queda marcado como relevante');
cmp_ok($ob->{relevance_score}, '>', 0, 'el Order Block expone una puntuación auditable');

my ($fvg) = grep { ($_->{direction} // '') eq 'bull' } @{ $smc->get_fvg_zones() };
ok($fvg, 'detecta Fair Value Gap alcista de tres velas');
is($fvg->{formed_at}, 3, 'FVG aparece solo al cerrar la tercera vela del patrón');
is($fvg->{bottom}, 102, 'FVG conserva el borde inferior correcto');
is($fvg->{top}, 103, 'FVG conserva el borde superior correcto');
is($fvg->{status}, 'mitigated', 'FVG registra su mitigación en el resultado analítico');
is($fvg->{mitigated_at}, 4, 'FVG conserva la vela exacta de mitigación');
is($fvg->{fill_ratio}, 1, 'FVG mitigado registra fill completo');

is($ob->{status}, 'mitigated', 'Order Block registra su mitigación en el motor');
is($ob->{first_touch_at}, 9, 'Order Block registra la primera penetración real');
is($ob->{end_index}, 13, 'Order Block se mitiga al llenar por completo el rango High/Low');

my $wick_only = [{
    direction => 'bull', top => 10, bottom => 8, triggered_by => -1,
}];
Market::Indicators::SMC_Structures::_annotate_order_block_lifecycle(
    [{ high => 11, low => 7, close => 9 }], $wick_only,
);
is($wick_only->[0]{status}, 'mitigated',
    'una mecha que atraviesa el bloque lo mitiga pero no lo invalida si el cierre permanece dentro');

my $closed_through = [{
    direction => 'bear', top => 12, bottom => 10, triggered_by => -1,
}];
Market::Indicators::SMC_Structures::_annotate_order_block_lifecycle(
    [{ high => 13, low => 9, close => 13 }], $closed_through,
);
is($closed_through->[0]{status}, 'mitigated',
    'la referencia High/Low usa un único estado final de mitigación');

my $prefix = smc_for(7);
is_deeply($prefix->get_bos_events(), [], 'antes de la vela 8 no existe el BOS futuro');
is_deeply($prefix->get_ob_zones(), [], 'antes del BOS no existe su Order Block');
my ($prefix_fvg) = grep { ($_->{formed_at} // -1) == 3 } @{ $prefix->get_fvg_zones() };
ok($prefix_fvg, 'el FVG ya confirmado se conserva en un cálculo de Replay');

my $snapshot = $smc->snapshot_at(7);
is_deeply($snapshot->{bos}, [], 'snapshot_at no expone BOS futuros');
is_deeply($snapshot->{order_blocks}, [], 'snapshot_at no expone Order Blocks futuros');
my ($snapshot_fvg) = grep { ($_->{formed_at} // -1) == 3 } @{ $snapshot->{fvgs} };
ok($snapshot_fvg, 'snapshot_at conserva FVGs confirmados antes del cursor');
my ($snapshot_ob) = grep { ($_->{triggered_by} // -1) == 8 } @{ $smc->snapshot_at(8)->{order_blocks} };
ok($snapshot_ob->{active}, 'snapshot_at conserva activo el Order Block antes de su mitigación');

my ($early_fvg) = grep { ($_->{formed_at} // -1) == 3 } @{ $smc->snapshot_at(3)->{fvgs} };
ok($early_fvg, 'FVG está disponible aunque aún no haya suficientes velas para pivotes');
is($early_fvg->{status}, 'active', 'snapshot temprano no mitiga el FVG con velas futuras');
is($early_fvg->{fill_ratio}, 0, 'snapshot temprano conserva fill correcto al cursor');

done_testing();
