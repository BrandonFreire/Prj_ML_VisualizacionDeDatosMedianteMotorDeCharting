package Market::ML::FeatureExtractor;

use strict;
use warnings;


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
    die 'FeatureExtractor::extract: window debe ser un entero >= 2'
        unless defined $window && $window =~ /^\d+$/ && $window >= 2;
    $window += 0;

    my $n = scalar @$candles;
    return {
        feature_names => [qw(return_1 trend_return volatility atr_pct volume_ratio)],
        window => $window, rows => [], max_visible_index => -1,
        replay_safe => 1,
    } unless $n;
    my $max_idx = $args{max_visible_index};
    $max_idx = $n - 1 unless defined $max_idx;
    die 'FeatureExtractor::extract: max_visible_index debe ser un entero no negativo'
        unless $max_idx =~ /^\d+$/;
    $max_idx += 0;
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
        die "FeatureExtractor: atr_series[$i] invalido"
            if defined($atr) && (!_finite($atr) || $atr < 0);
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
    die "FeatureExtractor: vela $index invalida"
        unless ref($candle) eq 'HASH';
    for my $field (qw(high low close)) {
        die "FeatureExtractor: vela $index sin $field numerico finito"
            unless _finite($candle->{$field});
    }
    die "FeatureExtractor: vela $index con high menor que low"
        if $candle->{high} < $candle->{low};
    die "FeatureExtractor: vela $index con close fuera de high/low"
        if $candle->{close} < $candle->{low} || $candle->{close} > $candle->{high};
    die "FeatureExtractor: vela $index con close cero"
        if $candle->{close} == 0;
    if (defined $candle->{volume}) {
        die "FeatureExtractor: vela $index con volumen invalido"
            unless _finite($candle->{volume}) && $candle->{volume} >= 0;
    }
}

sub _finite {
    my ($value) = @_;
    return 0 unless defined $value && $value =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/;
    return 0 if $value != $value;
    return 0 if abs($value) > 1e300;
    return 1;
}

1;
