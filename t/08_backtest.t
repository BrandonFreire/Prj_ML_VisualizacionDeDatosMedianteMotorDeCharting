use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Backtest;

sub candle {
    my ($i, $open, $high, $low, $close) = @_;
    return {
        time => $i * 60, open => $open, high => $high, low => $low,
        close => $close, volume => 1,
    };
}

my $engine = Market::Backtest->new(
    initial_capital => 10_000,
    risk_per_trade  => 0.01,
    commission_bps  => 0,
    slippage_bps    => 0,
);

my $result = $engine->run(
    candles => [
        candle(0, 100, 200, 50, 100),
        candle(1, 100, 101, 99, 101),
        candle(2, 101, 105, 100, 104),
        candle(3, 100, 101, 97, 98),
        candle(4, 98, 100, 95, 96),
    ],
    signals => [
        { index => 0, side => 'LONG',  stop_price => 98,  take_profit_price => 104 },
        { index => 2, side => 'SHORT', stop_price => 102, take_profit_price => 96 },
        { index => 4, side => 'LONG',  stop_price => 96,  take_profit_price => 104 },
    ],
    regime_series => [
        { index => 0, state => 'RANGING', confidence => 0.8, trained_through => -1 },
        { index => 2, state => 'TREND_BULLISH', confidence => 0.7, trained_through => -1 },
    ],
);

is($result->{total_trades}, 2, 'ejecuta dos señales con apertura siguiente');
is($result->{trades}[0]{entry_index}, 1, 'LONG entra en la apertura de la vela siguiente');
is($result->{trades}[0]{exit_index}, 2, 'el high futuro no se usa en la vela de la señal');
is($result->{trades}[0]{exit_reason}, 'target', 'LONG alcanza el objetivo posterior');
is($result->{trades}[1]{side}, 'SHORT', 'acepta una señal SHORT tras cerrar LONG');
is($result->{trades}[1]{entry_index}, 3, 'SHORT entra en la apertura posterior a su señal');
is($result->{trades}[1]{exit_reason}, 'target', 'SHORT alcanza el objetivo por el mínimo de la vela');
is($result->{trades}[0]{regime_state}, 'RANGING',
    'etiqueta el trade con el régimen conocido al confirmarse la señal');
is($result->{trades}[1]{regime_state}, 'TREND_BULLISH',
    'cada trade conserva su propio régimen de origen');
is($result->{by_regime}{RANGING}{trades}, 1,
    'resume las operaciones por régimen sin alterar sus reglas');
is(sprintf('%.2f', $result->{final_equity}), '10404.00',
    'dimensiona cada operacion por riesgo y actualiza el capital');
is($result->{wins}, 2, 'registra operaciones ganadoras');
is($result->{win_rate}, 1, 'calcula la tasa de acierto');
ok($result->{replay_safe}, 'el resultado declara que no utiliza velas futuras para entrar');
is($result->{skipped_signals}[0]{reason}, 'no_next_open',
    'una señal en la ultima vela no se inventa una apertura futura');

my $collision_candles = [
    candle(0, 100, 100, 100, 100),
    candle(1, 100, 103, 97, 100),
];
my $collision_signal = [
    { index => 0, side => 'LONG', stop_price => 98, take_profit_price => 102 },
];
my $conservative = $engine->run(
    candles => $collision_candles, signals => $collision_signal,
);
is($conservative->{trades}[0]{exit_reason}, 'stop',
    'si SL y TP aparecen en la misma vela, el modo por defecto es conservador');
my $optimistic = $engine->run(
    candles => $collision_candles, signals => $collision_signal,
    intrabar_priority => 'target_first',
);
is($optimistic->{trades}[0]{exit_reason}, 'target',
    'permite medir sensibilidad con la prioridad alternativa explicita');
ok($optimistic->{final_equity} > $conservative->{final_equity},
    'la prioridad intrabar cambia el resultado de forma visible y auditable');

my $costs = Market::Backtest->new(
    initial_capital => 10_000, risk_per_trade => 0.01,
    commission_bps => 10, slippage_bps => 10,
)->run(
    candles => [ candle(0, 100, 100, 100, 100), candle(1, 100, 105, 99, 104) ],
    signals => [ { index => 0, side => 'LONG', stop_price => 98, take_profit_price => 104 } ],
);
is(sprintf('%.3f', $costs->{trades}[0]{entry_price}), '100.100',
    'slippage encarece la entrada LONG');
is(sprintf('%.3f', $costs->{trades}[0]{exit_price}), '103.896',
    'slippage reduce la salida LONG');
ok($costs->{trades}[0]{net_pnl} < $costs->{trades}[0]{gross_pnl},
    'comisiones y slippage reducen el resultado neto');
is(sprintf('%.6f', $costs->{final_equity}),
   sprintf('%.6f', 10_000 + $costs->{trades}[0]{net_pnl}),
   'el capital final incluye las comisiones de ambos lados exactamente una vez');

my $short_costs = Market::Backtest->new(
    initial_capital => 10_000, risk_per_trade => 0.01, slippage_bps => 10,
)->run(
    candles => [ candle(0, 100, 100, 100, 100), candle(1, 100, 101, 95, 96) ],
    signals => [ { index => 0, side => 'SHORT', stop_price => 102, take_profit_price => 96 } ],
);
is(sprintf('%.3f', $short_costs->{trades}[0]{entry_price}), '99.900',
    'slippage reduce el precio de entrada SHORT');
is(sprintf('%.3f', $short_costs->{trades}[0]{exit_price}), '96.096',
    'slippage encarece la salida SHORT');

my $end = $engine->run(
    candles => [ candle(0, 100, 100, 100, 100), candle(1, 100, 101, 99, 101) ],
    signals => [ { index => 0, side => 'LONG', stop_price => 95, take_profit_price => 110 } ],
);
is($end->{trades}[0]{exit_reason}, 'end_of_data',
    'cierra una posicion abierta al final de la muestra');

my $without_atr = $engine->run(
    candles => [ candle(0, 100, 100, 100, 100), candle(1, 100, 101, 99, 100) ],
    signals => [ { index => 0, side => 'LONG' } ],
);
is($without_atr->{total_trades}, 0, 'sin ATR ni niveles explicitos no abre una operacion');
is($without_atr->{skipped_signals}[0]{reason}, 'missing_or_invalid_risk_levels',
    'explica por que se descarta una señal sin control de riesgo');

done_testing();
