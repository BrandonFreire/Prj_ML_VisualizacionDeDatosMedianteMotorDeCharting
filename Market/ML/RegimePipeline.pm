package Market::ML::RegimePipeline;

use strict;
use warnings;

use Market::ML::FeatureExtractor;
use Market::ML::RegimeClassifier;

# Fachada para una evaluacion temporal segura: extrae features, entrena en un
# tramo anterior y devuelve solamente la prediccion posterior. El modelo es
# no supervisado y clasifica contexto (rango/tendencia/volatilidad), no da una
# recomendacion de compra o venta.

sub new {
    my ($class, %args) = @_;
    return bless {
        feature_window => $args{feature_window} // 20,
        clusters       => $args{clusters}       // 3,
        min_samples    => $args{min_samples}    // 60,
        max_iter       => $args{max_iter}       // 50,
        training_ratio => $args{training_ratio} // 0.70,
    }, $class;
}

sub compute {
    my ($self, %args) = @_;
    my $candles = $args{candles} // [];
    die 'RegimePipeline::compute: candles debe ser un arrayref'
        unless ref($candles) eq 'ARRAY';
    my $last = $#$candles;
    return {
        available => 0, reason => 'no_candles', series => [],
        replay_safe => 1,
    } if $last < 0;

    my $visible_end = defined $args{max_visible_index}
        ? int($args{max_visible_index}) : $last;
    $visible_end = $last if $visible_end > $last;
    return {
        available => 0, reason => 'empty_visible_window', series => [],
        replay_safe => 1,
    } if $visible_end < 0;

    my $extractor = Market::ML::FeatureExtractor->new(
        window => $args{feature_window} // $self->{feature_window},
    );
    my $features = $extractor->extract(
        candles => $candles, atr_series => $args{atr_series},
        max_visible_index => $visible_end,
    );
    my $train_end = defined $args{train_end_index}
        ? int($args{train_end_index})
        : int($visible_end * $self->{training_ratio});
    $train_end = $visible_end if $train_end > $visible_end;
    my $classifier = Market::ML::RegimeClassifier->new(
        clusters    => $args{clusters}    // $self->{clusters},
        min_samples => $args{min_samples} // $self->{min_samples},
        max_iter    => $args{max_iter}    // $self->{max_iter},
    );
    my $result = $classifier->fit_predict(
        rows => $features->{rows}, train_end_index => $train_end,
    );
    return {
        %$result,
        feature_set       => $features,
        train_end_index   => $train_end,
        max_visible_index => $visible_end,
        replay_safe       => 1,
    };
}

1;
