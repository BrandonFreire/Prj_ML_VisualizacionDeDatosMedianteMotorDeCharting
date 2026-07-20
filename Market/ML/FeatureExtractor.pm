package Market::ML::FeatureExtractor;

use strict;
use warnings;

# Extrae variables numericas conocidas al cierre de cada vela. No centra ni
# escala usando muestras futuras: el escalado pertenece al clasificador y se
# ajusta exclusivamente con su tramo de entrenamiento.

sub new {
    my ($class, %args) = @_;
    return bless {
        window => $args{window} // 20,
    }, $class;
}

sub extract {
    my ($class_or_self, %args) = @_;
    my $candles = $args{candles} // [];
    die 'FeatureExtractor::extract: candles debe ser un arrayref'
        unless ref($candles) eq 'ARRAY';

    my $window = $args{window};
    $window = $class_or_self->{window} if !defined($window) && ref($class_or_self);
    $window = 20 unless defined $window;
    $window = int($window);
    die 'FeatureExtractor::extract: window debe ser >= 2' if $window < 2;

    my $n = scalar @$candles;
    my $max_idx = defined $args{max_visible_index}
        ? int($args{max_visible_index}) : $n - 1;
    $max_idx = $n - 1 if $max_idx > $n - 1;
    return {
        feature_names => [qw(return_1 trend_return volatility atr_pct volume_ratio)],
        window => $window, rows => [], max_visible_index => $max_idx,
        replay_safe => 1,
    } if $max_idx < 0;

    my $atr_series = $args{atr_series} // [];
    die 'FeatureExtractor::extract: atr_series debe ser un arrayref'
        unless ref($atr_series) eq 'ARRAY';

    my (@returns, @volumes, @closes, @rows);
    my ($sum_return, $sum_return_sq, $sum_volume) = (0, 0, 0);
    for my $i (0 .. $max_idx) {
        my $candle = $candles->[$i] // {};
        _validate_candle($candle, $i);
        my $close = $candle->{close} + 0;
        my $previous_close = $i ? $closes[$i - 1] : undef;
        my $return_1 = defined($previous_close) && $previous_close != 0
            ? $close / $previous_close - 1 : 0;
        my $volume = $candle->{volume} // 0;

        $returns[$i] = $return_1;
        $volumes[$i] = $volume + 0;
        $closes[$i]  = $close;
        $sum_return    += $return_1;
        $sum_return_sq += $return_1 * $return_1;
        $sum_volume    += $volume;
        if ($i >= $window) {
            my $old_return = $returns[$i - $window];
            my $old_volume = $volumes[$i - $window];
            $sum_return    -= $old_return;
            $sum_return_sq -= $old_return * $old_return;
            $sum_volume    -= $old_volume;
        }

        my $count = $i + 1 < $window ? $i + 1 : $window;
        my $mean_return = $count ? $sum_return / $count : 0;
        my $variance = $count > 1
            ? ($sum_return_sq - $count * $mean_return * $mean_return) / ($count - 1)
            : 0;
        $variance = 0 if $variance < 0 && $variance > -1e-14;
        my $volatility = $variance > 0 ? sqrt($variance) : 0;
        my $anchor = $i >= $window ? $closes[$i - $window] : undef;
        my $trend_return = defined($anchor) && $anchor != 0
            ? $close / $anchor - 1 : 0;
        my $range_pct = $close != 0
            ? abs(($candle->{high} // $close) - ($candle->{low} // $close)) / abs($close)
            : 0;
        my $atr = $atr_series->[$i];
        my $atr_pct = defined($atr) && $close != 0 ? abs($atr / $close) : $range_pct;
        my $avg_volume = $count ? $sum_volume / $count : 0;
        my $volume_ratio = $avg_volume > 0 ? $volume / $avg_volume : 1;
        my @features = map { _finite($_) ? $_ + 0 : 0 }
            ($return_1, $trend_return, $volatility, $atr_pct, $volume_ratio);

        push @rows, {
            index       => $i,
            time        => $candle->{time},
            available   => $i >= $window ? 1 : 0,
            features    => \@features,
            feature_map => {
                return_1     => $features[0], trend_return => $features[1],
                volatility   => $features[2], atr_pct      => $features[3],
                volume_ratio => $features[4],
            },
            atr_source  => defined($atr) ? 'atr_series' : 'bar_range',
            replay_safe => 1,
        };
    }

    return {
        feature_names      => [qw(return_1 trend_return volatility atr_pct volume_ratio)],
        window             => $window,
        rows               => \@rows,
        max_visible_index  => $max_idx,
        replay_safe        => 1,
    };
}

sub _validate_candle {
    my ($candle, $index) = @_;
    for my $field (qw(high low close)) {
        die "FeatureExtractor: vela $index sin $field"
            unless defined $candle->{$field};
    }
}

sub _finite {
    my ($value) = @_;
    return 0 unless defined $value;
    return 0 if $value != $value; # NaN
    return 0 if abs($value) > 1e300;
    return 1;
}

1;
