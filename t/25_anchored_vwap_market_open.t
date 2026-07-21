use strict;
use warnings;

use Test::More;
use Time::Local qw(timegm);
use lib '.';

use Market::MarketData;
use Market::Indicators::AnchoredVWAP;

my $TZ_OFFSET = -5 * 3600;

sub local_epoch {
    my ($day, $hour, $minute) = @_;
    return timegm(0, $minute, $hour, $day, 6, 2026 - 1900) - $TZ_OFFSET;
}

sub candle {
    my ($time, $price) = @_;
    return {
        time => $time, open => $price, high => $price + 1,
        low => $price - 1, close => $price + 0.25, volume => 100,
    };
}

sub market_from {
    my ($candles) = @_;
    my $market = Market::MarketData->new;
    $market->add_candle({ %$_ }) for @$candles;
    return $market;
}

my @candles;
for my $day (1, 2) {
    for my $hour (8 .. 11) {
        for my $minute (0, 30) {
            push @candles, candle(local_epoch($day, $hour, $minute), 100 + @candles);
        }
    }
}

my $indicator = Market::Indicators::AnchoredVWAP->new(
    anchor_mode => 'multipivot',
    market_open_hour => 9,
    market_open_minute => 30,
    market_timezone_offset_seconds => $TZ_OFFSET,
);
$indicator->compute_all(market_from(\@candles));

my @market_open = grep {
    ($_->{anchor_source} // '') eq 'market_open'
} @{ $indicator->get_vwap_lines };
is(scalar @market_open, 2, 'Market Open crea un ancla oficial por dia');
is_deeply([ map { $_->{anchor_idx} } @market_open ], [3, 11],
    'Market Open usa las velas de las 09:30 en la zona horaria del CSV');
ok(!scalar(grep {
    ($_->{anchor_metadata}{market_open_source} // '') ne 'official_open_time'
} @market_open), 'las anclas oficiales conservan metadata auditable');

my @short_day = map {
    candle(local_epoch(3, 7, $_), 200 + $_)
} (0, 30);
my $fallback = Market::Indicators::AnchoredVWAP->new(
    anchor_mode => 'multipivot',
    market_open_hour => 9,
    market_open_minute => 30,
    market_timezone_offset_seconds => $TZ_OFFSET,
);
$fallback->compute_all(market_from(\@short_day));
my ($merged) = grep {
    grep { $_ eq 'market_open' } @{ $_->{anchor_sources} // [] }
} @{ $fallback->get_vwap_lines };
ok($merged, 'si el feed termina antes de la apertura conserva un ancla de fallback');
is($merged->{market_open_metadata}{market_open_source},
    'first_available_session_candle',
    'el fallback queda distinguido de una apertura oficial');
is($merged->{anchor_idx}, 0, 'el fallback usa la primera vela disponible');

my $before_open = $indicator->get_vwap_lines_at(1);
ok(!scalar(grep {
    grep { $_ eq 'market_open' } @{ $_->{anchor_sources} // [] }
} @$before_open), 'Replay antes de 09:30 no inventa un fallback provisional');

done_testing();
