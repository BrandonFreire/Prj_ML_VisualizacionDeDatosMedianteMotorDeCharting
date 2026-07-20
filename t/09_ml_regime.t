use strict;
use warnings;

use Test::More;
use lib '.';

use Market::ML::FeatureExtractor;
use Market::ML::RegimeClassifier;
use Market::ML::RegimePipeline;

sub candle {
    my ($i, $close, $volume) = @_;
    return {
        time => $i * 60, open => $close - 0.2, high => $close + 1,
        low => $close - 1, close => $close, volume => $volume,
    };
}

my $candles = [ map { candle($_, 100 + $_, 10 + $_) } 0 .. 12 ];
my $extractor = Market::ML::FeatureExtractor->new(window => 3);
my $full_features = $extractor->extract(
    candles => $candles, atr_series => [ (0.5) x scalar(@$candles) ],
);
my $prefix_features = $extractor->extract(
    candles => $candles, atr_series => [ (0.5) x scalar(@$candles) ],
    max_visible_index => 5,
);
is($full_features->{rows}[2]{available}, 0, 'respeta el warm-up de la ventana');
ok($full_features->{rows}[3]{available}, 'la primera fila util aparece al completar la ventana');
is_deeply($prefix_features->{rows}[5], $full_features->{rows}[5],
    'las features de un cursor no cambian al agregar velas futuras');
is(scalar @{ $prefix_features->{rows} }, 6, 'la extracción se limita estrictamente al cursor');
ok($full_features->{rows}[5]{replay_safe}, 'cada feature se marca como segura para Replay');
ok($full_features->{rows}[5]{feature_map}{trend_return} > 0,
    'calcula tendencia usando solo cierres anteriores');

sub feature_row {
    my ($index, $features) = @_;
    return { index => $index, time => $index * 60, available => 1, features => $features };
}

my @rows;
for my $i (0 .. 29) {
    push @rows, feature_row($i,      [0,      0.000, 0.001, 0.001, 1.00]); # rango
    push @rows, feature_row($i + 30, [0.002,  0.050, 0.002, 0.003, 1.10]); # tendencia alcista
    push @rows, feature_row($i + 60, [0,      0.001, 0.040, 0.050, 1.80]); # volatilidad
}
push @rows,
    feature_row(90, [0.003, 0.060, 0.002, 0.003, 1.10]),
    feature_row(91, [0.000, 0.000, 0.001, 0.001, 1.00]),
    feature_row(92, [0.001, 0.001, 0.045, 0.055, 1.90]);

my $classifier = Market::ML::RegimeClassifier->new(
    clusters => 3, min_samples => 60, max_iter => 20,
);
my $result = $classifier->fit_predict(rows => \@rows, train_end_index => 89);
ok($result->{available}, 'entrena al disponer de suficientes observaciones históricas');
is($result->{model}{training_max_index}, 89, 'el modelo registra hasta qué vela fue entrenado');
is(scalar @{ $result->{series} }, 3, 'solo predice muestras posteriores al corte de entrenamiento');
is($result->{series}[0]{index}, 90, 'la primera predicción es estrictamente out-of-sample');
is($result->{series}[0]{state}, 'TREND_BULLISH', 'reconoce el cluster de tendencia alcista');
is($result->{series}[1]{state}, 'RANGING', 'reconoce el cluster de rango');
is($result->{series}[2]{state}, 'VOLATILE', 'reconoce el cluster de volatilidad');
ok($result->{series}[0]{confidence} > 0 && $result->{series}[0]{confidence} <= 1,
    'la confianza se mantiene en el intervalo interpretable [0,1]');
ok($result->{series}[0]{out_of_sample} && $result->{series}[0]{replay_safe},
    'cada predicción explicita que es OOS y segura para Replay');

my @with_future = (@rows, feature_row(500, [0.5, -9, 10, 10, 100]));
my $future_result = Market::ML::RegimeClassifier->new(
    clusters => 3, min_samples => 60, max_iter => 20,
)->fit_predict(rows => \@with_future, train_end_index => 89);
is_deeply(
    [ map { { index => $_->{index}, state => $_->{state}, cluster => $_->{cluster} } } @{ $result->{series} } ],
    [ map { { index => $_->{index}, state => $_->{state}, cluster => $_->{cluster} } } @{ $future_result->{series} }[0 .. 2] ],
    'una muestra futura no altera el entrenamiento ni las predicciones ya evaluables',
);

my $insufficient = Market::ML::RegimeClassifier->new(
    clusters => 3, min_samples => 10,
)->fit(rows => [ @rows[0 .. 4] ], train_end_index => 4);
ok(!$insufficient->{available}, 'rechaza un entrenamiento insuficiente sin inventar un régimen');
is($insufficient->{reason}, 'insufficient_training_samples', 'expone la causa del rechazo');

my @pipeline_candles = map {
    my $close = $_ < 35 ? 100 + (($_ % 2) ? 0.10 : -0.10)
              : $_ < 70 ? 100 + ($_ - 35) * 0.40
              : 114 + (($_ % 2) ? 2.0 : -2.0);
    candle($_, $close, $_ < 70 ? 20 : 80)
} 0 .. 99;
my $pipeline = Market::ML::RegimePipeline->new(
    feature_window => 10, clusters => 3, min_samples => 30,
);
my $pipeline_result = $pipeline->compute(
    candles => \@pipeline_candles,
    atr_series => [ (1) x scalar(@pipeline_candles) ],
    train_end_index => 70,
    max_visible_index => 90,
);
ok($pipeline_result->{available}, 'la tubería completa entrena y predice con velas y ATR');
is($pipeline_result->{feature_set}{max_visible_index}, 90,
    'la tubería no extrae una vela posterior al cursor visible');
is($pipeline_result->{series}[0]{index}, 71,
    'la tubería predice solo tras train_end_index');
ok($pipeline_result->{replay_safe}, 'la tubería conserva el contrato replay-safe');

done_testing();
