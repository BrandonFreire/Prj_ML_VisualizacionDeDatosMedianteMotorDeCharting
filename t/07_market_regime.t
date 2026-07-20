use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", '.';
use Test::More;

use MarketTestUtil qw(make_market);
use Market::Indicators::MarketRegime;
use Market::Overlays::SMC_Structures;

{
    package TestRegimeCanvas;
    sub new { bless { text => [] }, shift }
    sub delete { return }
    sub createText {
        my ($self, @args) = @_;
        my %opts = @args[2 .. $#args];
        push @{ $self->{text} }, $opts{-text};
        return;
    }
}
{
    package TestRegimeIndicator;
    sub new { bless { states => $_[1] }, $_[0] }
    sub get_states { return $_[0]->{states} }
}
{
    package TestSmcIndicator;
    sub new { bless {}, shift }
}
package main;

sub candles {
    return [ map {
        {
            time => $_ * 60, open => 100, high => 102, low => 98,
            close => $_ == 2 ? 100.8 : $_ == 3 ? 101.4 : 100,
            volume => $_ == 4 ? 200 : 10,
        }
    } 0 .. 8 ];
}

my $levels = [
    # Se vuelve externa solo desde la vela 6: antes debe tratarse como interna.
    { index => 1, price => 101, type => 'BSL', confirmed_at => 1,
      scope => 'external', scope_confirmed_at => 6 },
    { index => 2, price => 100.4, type => 'SSL', confirmed_at => 2,
      scope => 'internal' },
    # Grab interno en la vela 5, separado de los niveles que siguen activos.
    { index => 0, price => 98, type => 'SSL', confirmed_at => 0,
      scope => 'internal', resolved_at => 5, classification => 'GRAB' },
    # Grab externo y CHoCH externo producen TRANSITION en la vela 3.
    { index => 3, price => 103, type => 'BSL', confirmed_at => 3,
      scope => 'external', scope_confirmed_at => 3,
      resolved_at => 3, classification => 'BIG_GRAB' },
    # RUN externo junto con BOS externo valida la tendencia en la vela 4.
    { index => 4, price => 104, type => 'BSL', confirmed_at => 4,
      scope => 'external', scope_confirmed_at => 4,
      resolved_at => 4, classification => 'RUN' },
];
my $atr = [ (2) x 9 ];
my $regime = Market::Indicators::MarketRegime->new;
my $states = $regime->compute_from_inputs(
    candles          => candles(),
    atr_series       => $atr,
    liquidity_levels => $levels,
    choch_events     => [ {
        index => 3, direction => 'bear', scope => 'external',
        scope_confirmed_at => 3,
    } ],
    bos_events       => [ {
        index => 4, direction => 'bull', scope => 'external',
        scope_confirmed_at => 4,
    } ],
);

is($states->[1]{state}, 'LIQUIDEZ_INTERNA',
    'un nivel externo aun no confirmado se trata como liquidez interna');
is($states->[1]{nearest_liquidity_scope}, 'internal',
    'el scope efectivo no filtra una confirmacion externa futura');
is($states->[2]{state}, 'LIQUIDEZ_INTERNA',
    'selecciona la liquidez interna mas cercana cuando no hay externa disponible');
is($states->[3]{state}, 'TRANSITION',
    'BIG_GRAB externo y CHoCH externo producen transicion');
is($states->[4]{state}, 'TR_BULLISH',
    'RUN externo y BOS alcista externo validan tendencia alcista');
is($states->[5]{state}, 'ZM_MANIPULATION',
    'Grab interno sin estructura externa se marca como manipulacion');
is($states->[6]{nearest_liquidity_scope}, 'external',
    'el nivel pasa a externo solo tras scope_confirmed_at');
ok($states->[4]{confidence_score} > $states->[2]{confidence_score},
    'la evidencia de tendencia eleva la confianza del contexto');
ok($states->[4]{replay_safe}, 'cada estado declara que es seguro para Replay');

my $unknown = $regime->compute_from_inputs(
    candles => candles(), atr_series => [], liquidity_levels => [],
);
is($unknown->[0]{state}, 'UNKNOWN', 'sin ATR el contexto queda honestamente desconocido');

# Integracion con los indicadores locales y equivalencia de snapshot: no debe
# haber diferencia entre el prefijo historico y el resultado ya calculado.
require Market::Indicators::Liquidity;
require Market::Indicators::SMC_Structures;
my $market = make_market(candles());
my $lq = Market::Indicators::Liquidity->new(depth => 2, atr_period => 2);
$lq->compute_all($market);
my $smc = Market::Indicators::SMC_Structures->new(depth => 2);
$smc->set_liquidity_indicator($lq);
$smc->compute_all($market);
my $integrated = Market::Indicators::MarketRegime->new(
    liquidity_indicator => $lq,
    smc_indicator => $smc,
);
my $full = $integrated->compute_all($market);
is(scalar @$full, 9, 'compute_all integra MarketData, Liquidity y SMC');
my $snapshot = $integrated->snapshot_at(5);
is(scalar @$snapshot, 6, 'snapshot_at se limita al cursor de Replay');
is_deeply(
    [ map { { %$_, max_visible_index => 5 } } @{$full}[0 .. 5] ],
    $snapshot,
    'snapshot_at no altera los estados historicos con informacion futura',
);

my $canvas = TestRegimeCanvas->new;
my $overlay = Market::Overlays::SMC_Structures->new(
    indicator        => TestSmcIndicator->new,
    regime_indicator => TestRegimeIndicator->new($states),
    visibility => {
        smc_enabled => 1, show_market_regime => 1,
        show_premium_discount => 0, show_trendlines => 0, show_ob => 0,
        show_major_levels => 0, show_fvg => 0, show_bos => 0,
        show_choch => 0, show_fibonacci_auto => 0,
    },
);
$overlay->render($canvas, 0, 4, undef, 4);
like($canvas->{text}[0], qr/TR_BULLISH/, 'el overlay muestra el estado del nuevo motor de regimen');

done_testing();
