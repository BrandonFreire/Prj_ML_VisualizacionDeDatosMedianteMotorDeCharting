use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Indicators::Strategy_Builder;

sub candles {
    my ($n) = @_;
    return [ map {
        { time => $_ * 60, open => 100, high => 101, low => 99, close => 100, volume => 1 }
    } 0 .. $n - 1 ];
}

sub seed_series {
    my ($builder, $main, $confirmation) = @_;
    $builder->{_supertrend} = [ map { { direction => $_ } } @$main ];
    $builder->{_range_filter} = [ map { { direction => $_ } } @$confirmation ];
}

my $confirmed = Market::Indicators::Strategy_Builder->new(
    signal_main_indicator => 'supertrend',
    signal_confirmations => ['range_filter'],
    signal_confirmation_mode => 'AND',
    signal_expiry_bars => 1,
);
seed_series($confirmed, [-1, -1, 1, 1, -1, 1], [-1, -1, -1, 1, -1, 1]);
my $signals = $confirmed->compute_signals(candles(6));

is(scalar @$signals, 6, 'emite una fila de señales por vela');
is($signals->[3]{side}, 'LONG', 'espera la confirmación antes de emitir LONG');
is($signals->[3]{trigger_index}, 2, 'conserva la vela donde cambió el indicador principal');
is_deeply($signals->[3]{confirmations_passed}, ['range_filter'], 'expone la confirmación aprobada');
is($signals->[4]{side}, 'SHORT', 'emite SHORT al cambio bajista confirmado');
is($signals->[5]{side}, 'LONG', 'permite alternar a LONG después de SHORT');

my $expired = Market::Indicators::Strategy_Builder->new(
    signal_main_indicator => 'supertrend',
    signal_confirmations => ['range_filter'],
    signal_expiry_bars => 1,
);
seed_series($expired, [-1, -1, 1, 1, 1], [-1, -1, -1, -1, 1]);
my $expired_rows = $expired->compute_signals(candles(5));
ok(!scalar(grep { $_->{long_signal} } @$expired_rows), 'descarta una señal cuya confirmación llega después de expirar');

my $main_only = Market::Indicators::Strategy_Builder->new(
    signal_main_indicator => 'supertrend',
    signal_confirmations => [],
);
seed_series($main_only, [-1, -1, 1], [-1, -1, 1]);
my $main_rows = $main_only->compute_signals(candles(3));
is($main_rows->[2]{side}, 'LONG', 'sin confirmaciones la señal se emite en el cambio del indicador principal');
is($main_rows->[2]{confidence}, 1, 'la señal principal sin confirmaciones tiene confianza completa');

my $backtest = $main_only->run_backtest(
    candles => [
        { time => 0,   open => 100, high => 100, low => 100, close => 100, volume => 1 },
        { time => 60,  open => 100, high => 101, low => 99.5, close => 101, volume => 1 },
        { time => 120, open => 101, high => 103, low => 100, close => 102, volume => 1 },
    ],
    signals => [ { index => 0, side => 'LONG' } ],
    atr_series => [1, 1, 1],
    regime_series => [ { index => 0, state => 'RANGING', confidence => 0.8 } ],
    initial_capital => 10_000,
    stop_atr_multiple => 1,
    reward_risk => 2,
);
is($backtest->{total_trades}, 1, 'Strategy Builder delega sus señales al backtester');
is($backtest->{trades}[0]{exit_reason}, 'target',
    'el backtest delegado conserva el SL/TP derivado del ATR');
is($backtest->{trades}[0]{regime_state}, 'RANGING',
    'Strategy Builder reenvía el régimen al backtester delegado');

my @halftrend_prices = (100, 102, 104, 106, 104, 101, 98, 95, 93, 96, 100, 104, 108);
my @halftrend_candles = map {
    my $price = $halftrend_prices[$_];
    { time => $_ * 60, open => $price, high => $price + 1,
      low => $price - 1, close => $price, volume => 1 }
} 0 .. $#halftrend_prices;
my $halftrend_builder = Market::Indicators::Strategy_Builder->new(
    ht_amplitude => 2, ht_channel_dev => 2,
);
my $halftrend = $halftrend_builder->_compute_halftrend(
    \@halftrend_candles, [ (1) x @halftrend_candles ],
);
ok((grep { $_->{trend} == 1 } @$halftrend),
    'HalfTrend cambia a bajista cuando se confirma una reversión');
ok((grep { $_->{trend} == 0 } @$halftrend),
    'HalfTrend conserva y recupera el estado alcista');
cmp_ok(scalar(grep { $_->{flipped} } @$halftrend), '>=', 2,
    'HalfTrend registra giros en ambos sentidos en una secuencia completa');
ok(!(grep { $_->{atr_low} > $_->{value} || $_->{atr_high} < $_->{value} } @$halftrend),
    'las bandas HalfTrend siempre contienen su línea central');

done_testing();
