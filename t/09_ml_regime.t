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
    push @rows, feature_row($i,      [0,      0.000, 0.001, 0.001, 1.00]);
    push @rows, feature_row($i + 30, [0.002,  0.050, 0.002, 0.003, 1.10]);
    push @rows, feature_row($i + 60, [0,      0.001, 0.040, 0.050, 1.80]);
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

my @flat_rows = map {
    feature_row($_, [1, 1, 1, 1, 1])
} 0 .. 59;
my $flat = Market::ML::RegimeClassifier->new(
    clusters => 3, min_samples => 20,
)->fit(rows => \@flat_rows, train_end_index => 59);
ok(!$flat->{available}, 'no inventa regímenes cuando todas las observaciones son idénticas');
is($flat->{reason}, 'degenerate_training_data',
    'expone que no hay patrones distintos suficientes para formar clusters');
is($flat->{unique_training_points}, 1,
    'cuantifica los patrones distintos usados por la validación');

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

my $probabilistic = Market::ML::RegimePipeline->new(
    feature_window => 10, clusters => 3, min_samples => 30, algorithm => 'gmm_hmm',
)->compute(
    candles => \@pipeline_candles, atr_series => [ (1) x scalar(@pipeline_candles) ],
    train_end_index => 70, max_visible_index => 90,
);
ok($probabilistic->{available}, 'la opción GMM/HMM entrena solo con el tramo histórico');
is($probabilistic->{model}{algorithm}, 'diagonal_gmm_forward_hmm', 'identifica el modelo probabilístico usado');
is($probabilistic->{series}[0]{index}, 71, 'GMM/HMM emite únicamente estados posteriores al entrenamiento');
ok($probabilistic->{series}[0]{replay_safe}, 'los estados GMM/HMM se emiten con filtro causal');
my @probabilistic_future = (@pipeline_candles, map { candle($_ + 100, 1_000 + $_, 1) } 0 .. 4);
my $same_probabilistic_prefix = Market::ML::RegimePipeline->new(
    feature_window => 10, clusters => 3, min_samples => 30, algorithm => 'gmm_hmm',
)->compute(
    candles => \@probabilistic_future, atr_series => [ (1) x scalar(@probabilistic_future) ],
    train_end_index => 70, max_visible_index => 90,
);
is_deeply(
    [ map { { index => $_->{index}, state => $_->{state}, posterior => $_->{posterior} } } @{$same_probabilistic_prefix->{series}} ],
    [ map { { index => $_->{index}, state => $_->{state}, posterior => $_->{posterior} } } @{$probabilistic->{series}} ],
    'velas futuras fuera del cursor no modifican los estados GMM/HMM ya evaluables',
);

my $walk_forward = Market::ML::RegimePipeline->new(
    feature_window => 10, clusters => 3, min_samples => 30, max_iter => 20,
    algorithm => 'gmm_hmm', walk_forward => 1,
)->compute(
    candles => \@pipeline_candles, atr_series => [ (1) x scalar(@pipeline_candles) ],
    train_end_index => 70, max_visible_index => 75,
);
ok($walk_forward->{available}, 'walk-forward expansivo entrena y emite estados causales');
is($walk_forward->{model}{algorithm}, 'expanding_walk_forward_diagonal_gmm_forward_hmm',
    'distingue explícitamente el modo de reentrenamiento por barra');
is($walk_forward->{series}[0]{index}, 71, 'el primer estado walk-forward no usa su propia vela para el ajuste');
is($walk_forward->{series}[0]{trained_through}, 70, 'cada estado registra el último índice incluido al entrenar');
ok($walk_forward->{series}[0]{walk_forward} && $walk_forward->{series}[0]{replay_safe},
    'el resultado walk-forward conserva el contrato causal');

for my $case (
    [ 'OHLC invertido', [ { time => 0, high => 1, low => 2, close => 1.5 } ], qr/high menor que low/ ],
    [ 'cierre fuera de rango', [ { time => 0, high => 2, low => 1, close => 3 } ], qr/close fuera/ ],
    [ 'cierre cero', [ { time => 0, high => 1, low => 0, close => 0 } ], qr/close cero/ ],
    [ 'ATR negativo', [ candle(0, 100, 10) ], qr/atr_series\[0\] invalido/ ],
) {
    my $error;
    eval {
        Market::ML::FeatureExtractor->extract(
            candles => $case->[1], atr_series => $case->[0] eq 'ATR negativo' ? [-1] : [],
        );
    };
    $error = $@;
    like($error, $case->[2], "rechaza $case->[0] en vez de calcular features corruptas");
}

eval { Market::ML::RegimePipeline->new(training_ratio => 1.1) };
like($@, qr/training_ratio/, 'rechaza una proporción de entrenamiento fuera de rango');
eval { $pipeline->compute(candles => \@pipeline_candles, max_visible_index => -1) };
like($@, qr/max_visible_index/, 'rechaza cursor visible negativo en vez de truncarlo de forma ambigua');
my $empty_features = Market::ML::FeatureExtractor->extract(candles => []);
is_deeply($empty_features->{rows}, [], 'una serie vacía conserva un resultado vacío válido');
eval { $pipeline->compute(candles => \@pipeline_candles, clusters => 1) };
like($@, qr/clusters/, 'no normaliza silenciosamente una configuración ML inválida');
eval { Market::ML::RegimeClassifier->new(clusters => 1) };
like($@, qr/clusters/, 'el clasificador directo también rechaza una configuración inválida');

done_testing();
