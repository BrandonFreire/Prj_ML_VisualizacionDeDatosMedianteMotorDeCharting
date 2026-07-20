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

done_testing();
