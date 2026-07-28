package Market::ML::RegimePipeline;

use strict;
use warnings;

use Market::ML::FeatureExtractor;
use Market::ML::RegimeClassifier;
use Market::ML::GMM;
use Market::ML::HMM;


sub new {
    my ($class, %args) = @_;
    my $self = {
        feature_window => $args{feature_window} // 20,
        clusters       => $args{clusters}       // 3,
        min_samples    => $args{min_samples}    // 60,
        max_iter       => $args{max_iter}       // 50,
        training_ratio => $args{training_ratio} // 0.70,
        algorithm      => $args{algorithm}      // 'kmeans',
        hmm_sticky_bias => $args{hmm_sticky_bias} // 0.05,
        hmm_laplace_alpha => $args{hmm_laplace_alpha} // 1,
        gmm_variance_floor => $args{gmm_variance_floor} // 1e-6,
        walk_forward => $args{walk_forward} ? 1 : 0,
    };
    _validate_config($self);
    return bless $self, $class;
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
        ? $args{max_visible_index} : $last;
    die 'RegimePipeline::compute: max_visible_index debe ser un entero no negativo'
        unless $visible_end =~ /^\d+$/;
    $visible_end += 0;
    $visible_end = $last if $visible_end > $last;
    return {
        available => 0, reason => 'empty_visible_window', series => [],
        replay_safe => 1,
    } if $visible_end < 0;

    my $effective = {
        feature_window => $args{feature_window} // $self->{feature_window},
        clusters       => $args{clusters}       // $self->{clusters},
        min_samples    => $args{min_samples}    // $self->{min_samples},
        max_iter       => $args{max_iter}       // $self->{max_iter},
        training_ratio => $args{training_ratio} // $self->{training_ratio},
        algorithm      => $args{algorithm}      // $self->{algorithm},
        hmm_sticky_bias => $args{hmm_sticky_bias} // $self->{hmm_sticky_bias},
        hmm_laplace_alpha => $args{hmm_laplace_alpha} // $self->{hmm_laplace_alpha},
        gmm_variance_floor => $args{gmm_variance_floor} // $self->{gmm_variance_floor},
        walk_forward => exists $args{walk_forward} ? ($args{walk_forward} ? 1 : 0) : $self->{walk_forward},
    };
    _validate_config($effective);

    my $extractor = Market::ML::FeatureExtractor->new(
        window => $effective->{feature_window},
    );
    my $features = $extractor->extract(
        candles => $candles, atr_series => $args{atr_series},
        max_visible_index => $visible_end,
    );
    my $train_end = defined $args{train_end_index}
        ? $args{train_end_index}
        : int($visible_end * $effective->{training_ratio});
    die 'RegimePipeline::compute: train_end_index debe ser un entero no negativo'
        unless $train_end =~ /^\d+$/;
    $train_end += 0;
    $train_end = $visible_end if $train_end > $visible_end;
    my $result;
    if ($effective->{algorithm} eq 'gmm_hmm' && $effective->{walk_forward}) {
        $result = _gmm_hmm_walk_forward(
            rows => $features->{rows}, train_end_index => $train_end,
            clusters => $effective->{clusters}, min_samples => $effective->{min_samples},
            max_iter => $effective->{max_iter}, hmm_sticky_bias => $effective->{hmm_sticky_bias},
            hmm_laplace_alpha => $effective->{hmm_laplace_alpha},
            gmm_variance_floor => $effective->{gmm_variance_floor},
        );
    }
    elsif ($effective->{algorithm} eq 'gmm_hmm') {
        $result = _gmm_hmm_fit_predict(
            rows => $features->{rows}, train_end_index => $train_end,
            clusters => $effective->{clusters}, min_samples => $effective->{min_samples},
            max_iter => $effective->{max_iter}, hmm_sticky_bias => $effective->{hmm_sticky_bias},
            hmm_laplace_alpha => $effective->{hmm_laplace_alpha},
            gmm_variance_floor => $effective->{gmm_variance_floor},
        );
    }
    else {
        my $classifier = Market::ML::RegimeClassifier->new(
            clusters    => $effective->{clusters},
            min_samples => $effective->{min_samples},
            max_iter    => $effective->{max_iter},
        );
        $result = $classifier->fit_predict(
            rows => $features->{rows}, train_end_index => $train_end,
        );
    }
    return {
        %$result,
        feature_set       => $features,
        train_end_index   => $train_end,
        max_visible_index => $visible_end,
        replay_safe       => 1,
    };
}

sub _gmm_hmm_walk_forward {
    my (%args) = @_;
    my @targets = sort { $a->{index} <=> $b->{index} } grep {
        ($_->{available} // 0) && defined($_->{index}) && $_->{index} > $args{train_end_index}
            && ref($_->{features}) eq 'ARRAY' && _finite_vector($_->{features})
    } @{$args{rows}};
    my @series;
    my ($models_fitted, $last_unavailable);
    for my $target (@targets) {
        my @prefix = grep { defined($_->{index}) && $_->{index} <= $target->{index} } @{$args{rows}};
        my $fit = _gmm_hmm_fit_predict(
            %args, rows => \@prefix, train_end_index => $target->{index} - 1,
        );
        if (!$fit->{available}) {
            $last_unavailable = $fit->{model}{reason};
            next;
        }
        my ($prediction) = grep { $_->{index} == $target->{index} } @{$fit->{series}};
        next unless $prediction;
        $prediction = { %$prediction, walk_forward => 1 };
        push @series, $prediction;
        $models_fitted++;
    }
    return {
        available => @series ? 1 : 0,
        reason => @series ? undef : ($last_unavailable // 'insufficient_training_samples'),
        model => {
            available => @series ? 1 : 0,
            algorithm => 'expanding_walk_forward_diagonal_gmm_forward_hmm',
            initial_training_max_index => $args{train_end_index} + 0,
            models_fitted => $models_fitted // 0,
            replay_safe => 1,
        },
        series => \@series,
        replay_safe => 1,
    };
}

sub _gmm_hmm_fit_predict {
    my (%args) = @_;
    my @train = sort { $a->{index} <=> $b->{index} } grep {
        ($_->{available} // 0) && defined($_->{index}) && $_->{index} <= $args{train_end_index}
            && ref($_->{features}) eq 'ARRAY'
    } @{$args{rows}};
    my $dim = @train ? scalar @{$train[0]{features}} : 0;
    @train = grep { scalar(@{$_->{features}}) == $dim && _finite_vector($_->{features}) } @train;
    if (!$dim || @train < $args{min_samples}) {
        return _unavailable_model('insufficient_training_samples', \@train, \%args);
    }

    my (@means, @scales);
    for my $feature (0 .. $dim - 1) {
        my $mean = 0;
        $mean += $_->{features}[$feature] for @train;
        $mean /= @train;
        my $variance = 0;
        $variance += ($_->{features}[$feature] - $mean) ** 2 for @train;
        $variance /= @train;
        $means[$feature] = $mean + 0;
        $scales[$feature] = $variance > 1e-24 ? sqrt($variance) : 1;
    }
    my @train_points = map {
        my $row = $_;
        [ map { ($row->{features}[$_] - $means[$_]) / $scales[$_] } 0 .. $dim - 1 ]
    } @train;
    my $unique = _unique_point_count(\@train_points);
    if ($unique < $args{clusters}) {
        return _unavailable_model('degenerate_training_data', \@train, \%args,
            unique_training_points => $unique, required_distinct_points => $args{clusters});
    }

    my $gmm = Market::ML::GMM->new(
        n_components => $args{clusters}, max_iter => $args{max_iter},
        variance_floor => $args{gmm_variance_floor},
    )->fit(\@train_points);
    my $assignments = $gmm->hard_assignments(\@train_points);
    my $hmm = Market::ML::HMM->new(
        states => [ map { "C$_" } 0 .. $args{clusters} - 1 ],
        pi => Market::ML::HMM->estimate_initial_distribution(gmm_weights => $gmm->weights),
        A => Market::ML::HMM->estimate_transition_matrix(
            $assignments, n_states => $args{clusters},
            sticky_bias => $args{hmm_sticky_bias}, laplace_alpha => $args{hmm_laplace_alpha},
        ),
    );
    my $train_filter = $hmm->forward_filter($gmm->component_log_probabilities(\@train_points));
    my $raw_centroids = [ map {
        my $center = $_;
        [ map { $center->[$_] * $scales[$_] + $means[$_] } 0 .. $dim - 1 ]
    } @{$gmm->means} ];
    my %states = _semantic_states($raw_centroids);
    my $posterior = $train_filter->{final_posterior};
    my @series;
    for my $row (sort { $a->{index} <=> $b->{index} } grep {
        ($_->{available} // 0) && defined($_->{index}) && $_->{index} > $args{train_end_index}
            && ref($_->{features}) eq 'ARRAY' && scalar(@{$_->{features}}) == $dim
            && _finite_vector($_->{features})
    } @{$args{rows}}) {
        my $point = [ map { ($row->{features}[$_] - $means[$_]) / $scales[$_] } 0 .. $dim - 1 ];
        my $emission = $gmm->component_log_probabilities([$point])->[0];
        my ($next) = $hmm->forward_step(posterior => $posterior, log_emission => $emission);
        $posterior = $next;
        my $component = _argmax($posterior);
        push @series, {
            index => $row->{index}, time => $row->{time}, component => $component,
            cluster => $component, state => $states{$component} // 'UNKNOWN',
            posterior => [ @$posterior ], confidence => $posterior->[$component] + 0,
            trained_through => $args{train_end_index} + 0, out_of_sample => 1,
            replay_safe => 1,
        };
    }
    return {
        available => 1,
        model => {
            available => 1, algorithm => 'diagonal_gmm_forward_hmm', clusters => $args{clusters},
            feature_count => $dim, means => \@means, scales => \@scales,
            raw_centroids => $raw_centroids, state_by_cluster => \%states,
            gmm => $gmm->to_hash, hmm => $hmm->to_hash,
            training_max_index => $args{train_end_index} + 0, training_samples => scalar @train,
            unique_training_points => $unique, replay_safe => 1,
        },
        series => \@series, replay_safe => 1,
    };
}

sub _unavailable_model {
    my ($reason, $train, $args, %extra) = @_;
    return {
        available => 0,
        model => {
            available => 0, reason => $reason, training_max_index => $args->{train_end_index} + 0,
            training_samples => scalar @$train, required_samples => $args->{min_samples},
            replay_safe => 1, %extra,
        },
        series => [], replay_safe => 1,
    };
}

sub _semantic_states {
    my ($centroids) = @_;
    my @clusters = 0 .. $#$centroids;
    my ($volatile) = sort { ($centroids->[$b][2] // 0) <=> ($centroids->[$a][2] // 0) } @clusters;
    my %states = ($volatile => 'VOLATILE');
    my @other = grep { $_ != $volatile } @clusters;
    if (@other) {
        my ($trend) = sort {
            abs($centroids->[$b][1] // 0) <=> abs($centroids->[$a][1] // 0)
        } @other;
        $states{$trend} = ($centroids->[$trend][1] // 0) >= 0 ? 'TREND_BULLISH' : 'TREND_BEARISH';
        $states{$_} = 'RANGING' for grep { $_ != $trend } @other;
    }
    return %states;
}

sub _argmax {
    my ($values) = @_;
    my $best = 0;
    for my $index (1 .. $#$values) {
        $best = $index if $values->[$index] > $values->[$best];
    }
    return $best;
}

sub _unique_point_count {
    my ($points) = @_;
    my %seen;
    $seen{join "\x1e", map { sprintf '%.15g', $_ } @$_} = 1 for @$points;
    return scalar keys %seen;
}

sub _finite_vector {
    my ($vector) = @_;
    return 0 unless ref($vector) eq 'ARRAY' && @$vector;
    for my $value (@$vector) {
        return 0 unless defined $value
            && $value =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/
            && $value == $value && abs($value) <= 1e300;
    }
    return 1;
}

sub _validate_config {
    my ($cfg) = @_;
    die 'RegimePipeline: feature_window debe ser entero >= 2'
        unless defined $cfg->{feature_window} && $cfg->{feature_window} =~ /^\d+$/ && $cfg->{feature_window} >= 2;
    die 'RegimePipeline: clusters debe ser entero >= 2'
        unless defined $cfg->{clusters} && $cfg->{clusters} =~ /^\d+$/ && $cfg->{clusters} >= 2;
    die 'RegimePipeline: min_samples debe ser entero >= clusters'
        unless defined $cfg->{min_samples} && $cfg->{min_samples} =~ /^\d+$/ && $cfg->{min_samples} >= $cfg->{clusters};
    die 'RegimePipeline: max_iter debe ser entero >= 1'
        unless defined $cfg->{max_iter} && $cfg->{max_iter} =~ /^\d+$/ && $cfg->{max_iter} >= 1;
    die 'RegimePipeline: training_ratio debe estar entre 0 y 1'
        unless defined $cfg->{training_ratio}
            && $cfg->{training_ratio} =~ /^(?:0(?:\.\d+)?|1(?:\.0+)?)$/;
    die 'RegimePipeline: algorithm debe ser kmeans o gmm_hmm'
        unless ($cfg->{algorithm} // '') eq 'kmeans' || $cfg->{algorithm} eq 'gmm_hmm';
    for my $field (qw(hmm_sticky_bias hmm_laplace_alpha gmm_variance_floor)) {
        die "RegimePipeline: $field debe ser numerico no negativo"
            unless defined $cfg->{$field}
                && $cfg->{$field} =~ /^\d+(?:\.\d*)?(?:[eE][+-]?\d+)?$/
                && $cfg->{$field} >= 0;
    }
    die 'RegimePipeline: gmm_variance_floor debe ser mayor que cero'
        unless $cfg->{gmm_variance_floor} > 0;
    die 'RegimePipeline: walk_forward debe ser booleano'
        unless defined $cfg->{walk_forward} && ($cfg->{walk_forward} == 0 || $cfg->{walk_forward} == 1);
}

1;
