package Market::ML::RegimeClassifier;

use strict;
use warnings;

# K-means determinista para clasificar contexto, no para predecir precio.
# Se ajusta hasta train_end_index y sus predicciones solo se emiten despues de
# ese corte. Esto permite una evaluacion walk-forward sin fuga temporal.

sub new {
    my ($class, %args) = @_;
    return bless {
        clusters   => $args{clusters}   // 3,
        min_samples=> $args{min_samples}// 60,
        max_iter   => $args{max_iter}   // 50,
        _model     => undef,
    }, $class;
}

sub fit {
    my ($self, %args) = @_;
    my $rows = $args{rows} // [];
    die 'RegimeClassifier::fit: rows debe ser un arrayref'
        unless ref($rows) eq 'ARRAY';
    my $train_end = $args{train_end_index};
    $train_end = _last_index($rows) unless defined $train_end;
    my $clusters = int($args{clusters} // $self->{clusters});
    my $min_samples = int($args{min_samples} // $self->{min_samples});
    my $max_iter = int($args{max_iter} // $self->{max_iter});
    $clusters = 2 if $clusters < 2;
    $min_samples = $clusters if $min_samples < $clusters;
    $max_iter = 1 if $max_iter < 1;

    my @train = grep {
        ($_->{available} // 0) && defined($_->{index}) && $_->{index} <= $train_end
            && ref($_->{features}) eq 'ARRAY'
    } @$rows;
    my $dim = @train ? scalar @{ $train[0]{features} } : 0;
    @train = grep { scalar(@{ $_->{features} }) == $dim && _finite_vector($_->{features}) } @train;
    if ($dim == 0 || @train < $min_samples) {
        return $self->{_model} = {
            available => 0, reason => 'insufficient_training_samples',
            training_max_index => $train_end, training_samples => scalar @train,
            required_samples => $min_samples, replay_safe => 1,
        };
    }

    my (@means, @scales);
    for my $d (0 .. $dim - 1) {
        my $mean = 0;
        $mean += $_->{features}[$d] for @train;
        $mean /= scalar @train;
        my $variance = 0;
        $variance += ($_->{features}[$d] - $mean) ** 2 for @train;
        $variance /= scalar @train;
        $means[$d] = $mean + 0;
        $scales[$d] = $variance > 1e-24 ? sqrt($variance) : 1;
    }
    my @points = map {
        my $row = $_;
        [ map { ($row->{features}[$_] - $means[$_]) / $scales[$_] } 0 .. $dim - 1 ]
    } @train;
    my @centroids = _initial_centroids(\@points, $clusters);
    my @assignments = (0) x @points;
    my $iterations = 0;
    for my $iteration (1 .. $max_iter) {
        $iterations = $iteration;
        my $changed = 0;
        for my $i (0 .. $#points) {
            my $cluster = _nearest_cluster($points[$i], \@centroids);
            $changed = 1 if $cluster != $assignments[$i];
            $assignments[$i] = $cluster;
        }
        my (@sums, @counts);
        for my $cluster (0 .. $clusters - 1) {
            $sums[$cluster] = [ (0) x $dim ];
            $counts[$cluster] = 0;
        }
        for my $i (0 .. $#points) {
            my $cluster = $assignments[$i];
            $counts[$cluster]++;
            $sums[$cluster][$_] += $points[$i][$_] for 0 .. $dim - 1;
        }
        for my $cluster (0 .. $clusters - 1) {
            next unless $counts[$cluster];
            $centroids[$cluster] = [ map {
                $sums[$cluster][$_] / $counts[$cluster]
            } 0 .. $dim - 1 ];
        }
        last unless $changed;
    }

    my @raw_centroids = map {
        my $centroid = $_;
        [ map { $centroid->[$_] * $scales[$_] + $means[$_] } 0 .. $dim - 1 ]
    } @centroids;
    my %states = _semantic_states(\@raw_centroids);
    my $model = {
        available          => 1,
        algorithm          => 'deterministic_kmeans',
        clusters           => $clusters,
        feature_count      => $dim,
        means              => \@means,
        scales             => \@scales,
        centroids          => \@centroids,
        raw_centroids      => \@raw_centroids,
        state_by_cluster   => \%states,
        training_max_index => $train_end + 0,
        training_samples   => scalar @train,
        iterations         => $iterations,
        replay_safe        => 1,
    };
    return $self->{_model} = $model;
}

sub predict {
    my ($self, %args) = @_;
    my $rows = $args{rows} // [];
    die 'RegimeClassifier::predict: rows debe ser un arrayref'
        unless ref($rows) eq 'ARRAY';
    my $model = $args{model} // $self->{_model} // {};
    return [] unless $model->{available};
    my $start = defined $args{start_index}
        ? $args{start_index} : $model->{training_max_index} + 1;
    # Por defecto se prohíbe etiquetar el entrenamiento como si fuera una
    # predicción. Puede habilitarse explícitamente solo para inspección.
    $start = $model->{training_max_index} + 1 unless $args{allow_in_sample};

    my @series;
    for my $row (@$rows) {
        next unless ($row->{available} // 0) && defined($row->{index}) && $row->{index} >= $start;
        next unless ref($row->{features}) eq 'ARRAY'
                 && scalar(@{ $row->{features} }) == $model->{feature_count}
                 && _finite_vector($row->{features});
        my @point = map {
            ($row->{features}[$_] - $model->{means}[$_]) / $model->{scales}[$_]
        } 0 .. $model->{feature_count} - 1;
        my ($cluster, $distance) = _nearest_cluster(\@point, $model->{centroids}, 1);
        push @series, {
            index           => $row->{index},
            time            => $row->{time},
            cluster         => $cluster,
            state           => $model->{state_by_cluster}{$cluster} // 'UNKNOWN',
            distance        => sqrt($distance) + 0,
            confidence      => (1 / (1 + sqrt($distance))) + 0,
            trained_through => $model->{training_max_index},
            out_of_sample   => $row->{index} > $model->{training_max_index} ? 1 : 0,
            replay_safe     => 1,
        };
    }
    return \@series;
}

sub fit_predict {
    my ($self, %args) = @_;
    my $model = $self->fit(%args);
    return {
        available => 0, model => $model, series => [],
        replay_safe => 1,
    } unless $model->{available};
    my $series = $self->predict(rows => $args{rows}, model => $model);
    return {
        available => 1, model => $model, series => $series,
        replay_safe => 1,
    };
}

sub get_model { return $_[0]->{_model} }

sub _initial_centroids {
    my ($points, $clusters) = @_;
    my @centroids = ( [ @{ $points->[0] } ] );
    while (@centroids < $clusters) {
        my ($best_index, $best_distance) = (0, -1);
        for my $i (0 .. $#$points) {
            my (undef, $nearest) = _nearest_cluster($points->[$i], \@centroids, 1);
            if ($nearest > $best_distance) {
                ($best_index, $best_distance) = ($i, $nearest);
            }
        }
        push @centroids, [ @{ $points->[$best_index] } ];
    }
    return @centroids;
}

sub _nearest_cluster {
    my ($point, $centroids, $return_distance) = @_;
    my ($best, $best_distance) = (0, 9e99);
    for my $cluster (0 .. $#$centroids) {
        my $distance = _distance_squared($point, $centroids->[$cluster]);
        ($best, $best_distance) = ($cluster, $distance) if $distance < $best_distance;
    }
    return $return_distance ? ($best, $best_distance) : $best;
}

sub _semantic_states {
    my ($centroids) = @_;
    my @clusters = 0 .. $#$centroids;
    # Indices del FeatureExtractor: trend_return=1, volatility=2.
    my ($volatile) = sort {
        ($centroids->[$b][2] // 0) <=> ($centroids->[$a][2] // 0)
    } @clusters;
    my %states = ($volatile => 'VOLATILE');
    my @rest = grep { $_ != $volatile } @clusters;
    if (@rest) {
        my ($trend) = sort {
            abs($centroids->[$b][1] // 0) <=> abs($centroids->[$a][1] // 0)
        } @rest;
        my $direction = ($centroids->[$trend][1] // 0) >= 0 ? 'BULLISH' : 'BEARISH';
        $states{$trend} = "TREND_$direction";
        $states{$_} = 'RANGING' for grep { $_ != $trend } @rest;
    }
    return %states;
}

sub _distance_squared {
    my ($a, $b) = @_;
    my $distance = 0;
    $distance += ($a->[$_] - $b->[$_]) ** 2 for 0 .. $#$a;
    return $distance;
}

sub _last_index {
    my ($rows) = @_;
    my @indexes = map { $_->{index} } grep { defined $_->{index} } @$rows;
    return @indexes ? (sort { $b <=> $a } @indexes)[0] : -1;
}

sub _finite_vector {
    my ($vector) = @_;
    return 0 unless ref($vector) eq 'ARRAY' && @$vector;
    for my $value (@$vector) {
        return 0 unless defined $value && $value == $value && abs($value) <= 1e300;
    }
    return 1;
}

1;
