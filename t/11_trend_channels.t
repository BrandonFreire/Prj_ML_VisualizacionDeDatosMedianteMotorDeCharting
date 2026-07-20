use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Indicators::TrendChannels;

sub fixture {
    my (%args) = @_;
    my $count     = $args{count} // 110;
    my $direction = $args{direction} // 'bullish';
    my $width     = $args{width} // 5;
    my $slope     = $args{slope} // 0.05;
    my $atr       = $args{atr} // 5;
    my @candles;
    for my $i (0 .. $count - 1) {
        my $phase = $i % 20;
        my $leg = $phase <= 10 ? $phase / 10 : (20 - $phase) / 10;
        my ($lower, $upper, $close);
        if ($direction eq 'bearish') {
            $upper = 125 - $i * $slope;
            $lower = $upper - $width;
            $close = $upper - $width * $leg;
        } else {
            $lower = 100 + $i * $slope;
            $upper = $lower + $width;
            $close = $lower + $width * $leg;
        }
        if (defined $args{break_index} && $i == $args{break_index}) {
            $close = ($args{break_direction} // '') eq 'up'
                ? $upper + $atr * 0.55 : $lower - $atr * 0.55;
        }
        elsif (defined $args{outside_from} && $i >= $args{outside_from}
               && $i <= ($args{outside_to} // $i)) {
            $close = $upper + $atr * 0.20;
        }
        push @candles, {
            time => $i * 60, open => $close, high => $close + 0.05,
            low => $close - 0.05, close => $close, volume => 1000 + $i,
        };
    }
    return (\@candles, [ ($atr) x $count ]);
}

sub detect {
    my (%args) = @_;
    my ($candles, $atr) = fixture(%args);
    my $channels = Market::Indicators::TrendChannels->compute(
        candles => $candles, atr_series => $atr,
        max_visible_index => $#$candles,
    );
    return ($channels, $candles, $atr);
}

my ($bullish) = detect(direction => 'bullish');
my $bull = $bullish->[0];
ok($bull, 'detecta un canal alcista con pivotes confirmados');
is($bull->{type}, 'trend_channel', 'usa un tipo analítico dedicado');
is($bull->{direction}, 'bullish', 'clasifica correctamente el canal alcista');
cmp_ok($bull->{duration_minutes}, '>=', 60, 'exige duración temporal real mínima');
cmp_ok($bull->{lower_touches}, '>=', 2, 'el canal alcista tiene contactos inferiores');
cmp_ok($bull->{upper_touches}, '>=', 2, 'el canal alcista tiene contactos superiores');
cmp_ok($bull->{containment_ratio}, '>=', 0.85, 'la mayor parte de cierres queda contenida');
cmp_ok($bull->{touch_distribution_ratio}, '>', 0.5,
    'cuantifica que los contactos están distribuidos sobre el canal completo');
cmp_ok($bull->{width_in_atr}, '>=', 0.75, 'rechaza anchos menores al umbral ATR');
cmp_ok($bull->{width_in_atr}, '<=', 8, 'rechaza anchos mayores al umbral ATR');
ok(abs(($bull->{upper_y2} - $bull->{lower_y2}) - ($bull->{upper_y1} - $bull->{lower_y1})) < 1e-8,
    'las dos líneas del canal son paralelas');
ok($bull->{anchor1}{confirmed} && $bull->{anchor2}{confirmed},
    'los anclajes se exponen como pivotes confirmados');
ok($bull->{replay_safe}, 'el resultado declara seguridad para Replay');

my ($bearish) = detect(direction => 'bearish');
is($bearish->[0]{direction}, 'bearish', 'detecta también canales bajistas');
cmp_ok($bearish->[0]{total_touches}, '>=', 4, 'el canal bajista exige contactos en ambos bordes');

my ($broken) = detect(direction => 'bullish', break_index => 96, break_direction => 'down');
is($broken->[0]{status}, 'broken', 'conserva un canal roto para auditoría');
is($broken->[0]{break_index}, 96, 'detiene la extensión en la ruptura fuerte');
is($broken->[0]{breakout_direction}, 'down', 'registra el sentido de la ruptura');

for my $case (
    [ 'duración insuficiente', { count => 65 } ],
    [ 'mercado lateral', { slope => 0 } ],
    [ 'cierres fuera de contención', { outside_from => 55, outside_to => 90 } ],
    [ 'canal demasiado estrecho', { width => 2, atr => 5 } ],
    [ 'canal demasiado ancho', { width => 45, atr => 5 } ],
) {
    my ($channels) = detect(%{ $case->[1] });
    is(scalar @$channels, 0, "rechaza $case->[0]");
}

my ($candles, $atr) = fixture(direction => 'bullish');
my $prefix = Market::Indicators::TrendChannels->compute(
    candles => $candles, atr_series => $atr, max_visible_index => 90,
);
my @extended = (@$candles, map {
    { time => ($_ + 110) * 60, open => 200, high => 201, low => 199, close => 200, volume => 1 }
} 0 .. 4);
my $same_prefix = Market::Indicators::TrendChannels->compute(
    candles => \@extended, atr_series => [ @$atr, (1) x 5 ], max_visible_index => 90,
);
is_deeply(
    [ map { { direction => $_->{direction}, start => $_->{start_index}, end => $_->{end_index}, score => $_->{score} } } @$prefix ],
    [ map { { direction => $_->{direction}, start => $_->{start_index}, end => $_->{end_index}, score => $_->{score} } } @$same_prefix ],
    'velas posteriores al cursor no alteran el cálculo histórico',
);

$candles->[30]{time} = $candles->[29]{time};
my $duplicate_time = Market::Indicators::TrendChannels->compute(
    candles => $candles, atr_series => $atr,
);
is(scalar @$duplicate_time, 0, 'rechaza timestamps duplicados en lugar de calcular una pendiente falsa');

is(
    Market::Indicators::TrendChannels::_touch_distribution(
        { upper => [{ index => 10 }], lower => [{ index => 20 }] }, 0, 100,
    ),
    0.1,
    'la distribución usa la duración total del canal y no se vuelve uno por identidad',
);
is(
    Market::Indicators::TrendChannels::_time_seconds('2026-07-20T12:00:00+02:00'),
    Market::Indicators::TrendChannels::_time_seconds('2026-07-20T10:00:00Z'),
    'normaliza correctamente offsets ISO al comparar duración y orden temporal',
);

done_testing();
