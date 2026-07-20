package MarketTestUtil;

use strict;
use warnings;
use Exporter qw(import);

use lib '.';
use Market::MarketData;

our @EXPORT_OK = qw(make_market sample_candles atr_candles);

sub make_market {
    my ($candles, $timeframe) = @_;
    $timeframe //= '1';

    my $market = Market::MarketData->new();
    $market->add_candle({ %$_ }) for @$candles;
    $market->set_timeframe($timeframe);
    return $market;
}

# Diez velas de un minuto alineadas a un límite de cinco minutos.  Los datos
# son artificiales para que cada resultado esperado sea fácil de auditar.
sub sample_candles {
    my $base = 1_800_000_000;
    return [ map {
        {
            time   => $base + $_ * 60,
            open   => 100 + $_,
            high   => 101 + $_,
            low    =>  99 + $_,
            close  => 100.5 + $_,
            volume => 10 + $_,
        }
    } 0 .. 9 ];
}

sub atr_candles {
    return [
        { time => 0,   open => 9,  high => 10, low => 8,  close => 9,  volume => 1 },
        { time => 60,  open => 9,  high => 12, low => 9,  close => 11, volume => 1 },
        { time => 120, open => 11, high => 13, low => 10, close => 12, volume => 1 },
        { time => 180, open => 12, high => 14, low => 11, close => 13, volume => 1 },
    ];
}

1;
