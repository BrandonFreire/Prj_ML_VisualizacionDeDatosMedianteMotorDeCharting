use strict;
use warnings;

use FindBin;
use lib "$FindBin::Bin/lib", '.';
use Test::More;
use Scalar::Util qw(refaddr);

use MarketTestUtil qw(make_market sample_candles);

my $candles = sample_candles();
my $market  = make_market($candles);

is($market->size(), 10, 'almacena las velas de 1 minuto');
is(refaddr($market->get_active_candles()), refaddr($market->get_data()->{'1'}),
    'get_active_candles expone la serie activa mediante una API publica');

$market->build_timeframes();
my $all = $market->get_data();
is(scalar @{ $all->{'5'} }, 2, 'agrupa diez velas en dos velas de 5 minutos');
is(scalar @{ $all->{'15'} }, 1, 'agrupa diez velas en una vela de 15 minutos');
is(scalar @{ $all->{'1440'} }, 1, 'conserva una vela diaria para una única sesión');
is(scalar @{ $all->{'10080'} }, 1, 'conserva una vela semanal para una única semana');

$market->set_timeframe('5');
my $first_5m = $market->get_candle(0);
is_deeply(
    {
        time   => $candles->[0]{time},
        open   => 100,
        high   => 105,
        low    => 99,
        close  => 104.5,
        volume => 60,
    },
    $first_5m,
    'la agregación OHLCV de 5 minutos respeta open/high/low/close/volume',
);

$market->set_timeframe('1');
my $prefix = $market->clone_upto(3);
is($prefix->size(), 4, 'clone_upto crea un prefijo de datos para replay');
is($prefix->last_candle->{time}, $candles->[3]{time}, 'el prefijo termina en el cursor pedido');

my $volume_index_first = $market->build_volume_index('5');
my $volume_index_cached = $market->build_volume_index('5');
is(refaddr($volume_index_cached), refaddr($volume_index_first),
    'reutiliza el indice de volumen cacheado para la misma temporalidad y datos');

$market->merge_delta_row({
    time   => $candles->[-1]{time},
    open   => $candles->[-1]{open},
    high   => 115,
    low    => 106,
    close  => 114,
    volume => 7,
});
my $last = $market->last_candle();
is($market->size(), 10, 'merge_delta_row no duplica una vela con el mismo timestamp');
is($last->{high}, 115, 'merge_delta_row conserva el máximo acumulado');
is($last->{low}, 106, 'merge_delta_row conserva el mínimo acumulado');
is($last->{close}, 114, 'merge_delta_row actualiza el cierre');
is($last->{volume}, 26, 'merge_delta_row acumula el delta de volumen');

my $volume_index_after_delta = $market->build_volume_index('5');
isnt(refaddr($volume_index_after_delta), refaddr($volume_index_first),
    'una actualizacion de vela invalida el indice de volumen cacheado');
is(refaddr($market->build_volume_index('5')), refaddr($volume_index_after_delta),
    'el indice reconstruido vuelve a cachearse tras la invalidacion');

done_testing();
