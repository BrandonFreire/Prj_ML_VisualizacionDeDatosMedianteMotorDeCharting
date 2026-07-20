use strict;
use warnings;

use Test::More;
use lib '.';

use Market::MarketData;
use Market::Indicators::VolumeProfile;

sub market_from {
    my (@candles) = @_;
    my $market = Market::MarketData->new;
    $market->add_candle($_) for @candles;
    return $market;
}

my $market = market_from(
    { time => 0,  open => 100, high => 110, low => 90,  close => 100, volume => 100 },
    { time => 60, open => 105, high => 105, low => 105, close => 105, volume => 900 },
);
my $profile = Market::Indicators::VolumeProfile->new(num_bins => 20);
$profile->add_manual_anchor(0, 1);
$profile->compute_all($market);
my $result = $profile->get_latest_profile;
my $sum = 0;
$sum += $_->{volume} for @{$result->{bins}};
cmp_ok(abs($sum - 1_000), '<', 1e-8,
    'el volumen distribuido coincide con el volumen total incluso con una vela doji');
is($result->{total_vol}, 1_000, 'total_vol conserva el mismo contrato que la suma de bins');
cmp_ok(abs($result->{poc} - 105), '<=', 0.5,
    'el volumen concentrado de la vela doji determina el POC correcto');

my $flat_market = market_from(
    { time => 0,  open => 100, high => 100, low => 100, close => 100, volume => 20 },
    { time => 60, open => 100, high => 100, low => 100, close => 100, volume => 30 },
);
my $flat = Market::Indicators::VolumeProfile->new(num_bins => 10);
$flat->add_manual_anchor(0, 1);
$flat->compute_all($flat_market);
my $flat_result = $flat->get_latest_profile;
ok($flat_result, 'un mercado completamente plano aún produce un perfil válido');
is($flat_result->{poc}, 100, 'el POC plano conserva exactamente el único precio negociado');
is($flat_result->{total_vol}, 50, 'el perfil plano conserva todo el volumen');

eval { Market::Indicators::VolumeProfile->new(num_bins => 0) };
like($@, qr/num_bins/, 'rechaza un número de bins que causaría división por cero');
eval { Market::Indicators::VolumeProfile->new(value_area_pct => 1.1) };
like($@, qr/value_area_pct/, 'rechaza un porcentaje de value area fuera de rango');

done_testing();
