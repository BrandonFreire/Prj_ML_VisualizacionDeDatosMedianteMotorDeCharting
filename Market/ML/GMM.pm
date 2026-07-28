package Market::ML::GMM;

use strict;
use warnings;


use constant LOG_2PI => 1.8378770664093453;

sub new {
    my ($class, %args) = @_;
    my $components = $args{n_components} // $args{components} // 3;
    my $max_iter = $args{max_iter} // 100;
    my $tolerance = $args{tolerance} // 1e-5;
    my $variance_floor = $args{variance_floor} // 1e-6;
    die 'GMM::new: n_components must be a positive integer'
        unless $components =~ /^\d+$/ && $components > 0;
    die 'GMM::new: max_iter must be a positive integer'
        unless $max_iter =~ /^\d+$/ && $max_iter > 0;
    die 'GMM::new: tolerance must be positive'
        unless _positive($tolerance);
    die 'GMM::new: variance_floor must be positive'
        unless _positive($variance_floor);
    return bless {
        n_components => $components + 0,
        max_iter => $max_iter + 0,
        tolerance => $tolerance + 0,
        variance_floor => $variance_floor + 0,
        fitted => 0,
    }, $class;
}

sub fit {
    my ($self, $points) = @_;
    _validate_matrix($points, 'GMM::fit');
    my $n = @$points;
    my $d = @{$points->[0]};
    my $k = $self->{n_components};
    die 'GMM::fit: n_components exceeds sample count' if $k > $n;
    die 'GMM::fit: insufficient distinct points' if _unique_point_count($points) < $k;

    my $means = _initial_means($points, $k);
    my $global_variance = _global_variance($points, $d, $self->{variance_floor});
    my @variances = map { [ @$global_variance ] } 1 .. $k;
    my @weights = (1 / $k) x $k;
    my ($last_ll, $converged, $iterations) = (undef, 0, 0);

    for my $iteration (1 .. $self->{max_iter}) {
        $iterations = $iteration;
        my ($responsibilities, $ll) = _e_step($points, \@weights, $means, \@variances);
        if (defined $last_ll && abs($ll - $last_ll) <= $self->{tolerance}) {
            $converged = 1;
            last;
        }
        $last_ll = $ll;

        my @counts = (0) x $k;
        for my $row (@$responsibilities) {
            $counts[$_] += $row->[$_] for 0 .. $k - 1;
        }
        for my $component (0 .. $k - 1) {
            if ($counts[$component] <= 1e-12) {
                my $replacement = _farthest_point($points, $means);
                $means->[$component] = [ @{$points->[$replacement]} ];
                $variances[$component] = [ @$global_variance ];
                $weights[$component] = 1 / $n;
                next;
            }
            my @mean = (0) x $d;
            for my $i (0 .. $#$points) {
                $mean[$_] += $responsibilities->[$i][$component] * $points->[$i][$_]
                    for 0 .. $d - 1;
            }
            $mean[$_] /= $counts[$component] for 0 .. $d - 1;
            my @variance = (0) x $d;
            for my $i (0 .. $#$points) {
                my $weight = $responsibilities->[$i][$component];
                $variance[$_] += $weight * ($points->[$i][$_] - $mean[$_]) ** 2
                    for 0 .. $d - 1;
            }
            for my $index (0 .. $d - 1) {
                $variance[$index] = $variance[$index] / $counts[$component];
                $variance[$index] = $self->{variance_floor}
                    if $variance[$index] < $self->{variance_floor};
            }
            $means->[$component] = \@mean;
            $variances[$component] = \@variance;
            $weights[$component] = $counts[$component] / $n;
        }
        _normalize(\@weights);
    }

    my (undef, $log_likelihood) = _e_step($points, \@weights, $means, \@variances);
    $self->{n_features} = $d;
    $self->{n_samples_fit} = $n;
    $self->{means} = [ map { [ @$_ ] } @$means ];
    $self->{variances} = [ map { [ @$_ ] } @variances ];
    $self->{weights} = [ @weights ];
    $self->{converged} = $converged ? 1 : 0;
    $self->{n_iter} = $iterations;
    $self->{log_likelihood} = $log_likelihood + 0;
    $self->{fitted} = 1;
    return $self;
}

sub predict_proba {
    my ($self, $points) = @_;
    $self->_require_fitted;
    _validate_matrix($points, 'GMM::predict_proba', $self->{n_features});
    my ($responsibilities) = _e_step($points, $self->{weights}, $self->{means}, $self->{variances});
    return $responsibilities;
}

sub component_log_probabilities {
    my ($self, $points) = @_;
    $self->_require_fitted;
    _validate_matrix($points, 'GMM::component_log_probabilities', $self->{n_features});
    return [ map {
        my $point = $_;
        [ map { _log_gaussian($point, $self->{means}[$_], $self->{variances}[$_]) }
            0 .. $self->{n_components} - 1 ]
    } @$points ];
}

sub score_samples {
    my ($self, $points) = @_;
    $self->_require_fitted;
    _validate_matrix($points, 'GMM::score_samples', $self->{n_features});
    return [ map {
        my $point = $_;
        _log_sum_exp([ map {
            log($self->{weights}[$_] || 1e-300)
                + _log_gaussian($point, $self->{means}[$_], $self->{variances}[$_])
        } 0 .. $self->{n_components} - 1 ])
    } @$points ];
}

sub hard_assignments {
    my ($self, $points) = @_;
    my $proba = $self->predict_proba($points);
    return [ map { _argmax($_) } @$proba ];
}

sub sample_diagnostics {
    my ($self, $points) = @_;
    my $proba = $self->predict_proba($points);
    my $scores = $self->score_samples($points);
    my $log_k = $self->{n_components} > 1 ? log($self->{n_components}) : 1;
    my @out;
    for my $i (0 .. $#$proba) {
        my $probabilities = $proba->[$i];
        my $component = _argmax($probabilities);
        my $entropy = 0;
        $entropy -= $_ * log($_) for grep { $_ > 0 } @$probabilities;
        my $normalized = $entropy / $log_k;
        push @out, {
            component => $component,
            max_responsibility => $probabilities->[$component] + 0,
            entropy => $entropy + 0,
            normalized_entropy => $normalized + 0,
            predictability_score => (1 - $normalized) + 0,
            log_density => $scores->[$i] + 0,
        };
    }
    return \@out;
}

sub to_hash {
    my ($self) = @_;
    $self->_require_fitted;
    return {
        algorithm => 'diagonal_gmm', n_components => $self->{n_components},
        n_features => $self->{n_features}, n_samples_fit => $self->{n_samples_fit},
        max_iter => $self->{max_iter}, tolerance => $self->{tolerance},
        variance_floor => $self->{variance_floor}, weights => [ @{$self->{weights}} ],
        means => [ map { [ @$_ ] } @{$self->{means}} ],
        variances => [ map { [ @$_ ] } @{$self->{variances}} ],
        converged => $self->{converged}, n_iter => $self->{n_iter},
        log_likelihood => $self->{log_likelihood},
    };
}

sub from_hash {
    my ($class, $hash) = @_;
    die 'GMM::from_hash: invalid model' unless ref($hash) eq 'HASH';
    die 'GMM::from_hash: n_features must be a positive integer'
        unless defined($hash->{n_features}) && $hash->{n_features} =~ /^\d+$/
            && $hash->{n_features} > 0;
    my $self = $class->new(
        n_components => $hash->{n_components}, max_iter => $hash->{max_iter},
        tolerance => $hash->{tolerance}, variance_floor => $hash->{variance_floor},
    );
    _validate_matrix($hash->{means}, 'GMM::from_hash means', $hash->{n_features});
    die 'GMM::from_hash: wrong number of means'
        unless @{$hash->{means}} == $self->{n_components};
    _validate_matrix($hash->{variances}, 'GMM::from_hash variances', $hash->{n_features});
    die 'GMM::from_hash: wrong number of variance rows'
        unless @{$hash->{variances}} == $self->{n_components};
    for my $row (@{$hash->{variances}}) {
        for my $value (@$row) {
            die 'GMM::from_hash: variances must be positive' unless $value > 0;
        }
    }
    die 'GMM::from_hash: invalid weights'
        unless ref($hash->{weights}) eq 'ARRAY' && @{$hash->{weights}} == $self->{n_components};
    die 'GMM::from_hash: weights must be non-negative finite values'
        unless !grep { !_finite($_) || $_ < 0 } @{$hash->{weights}};
    my $weight_sum = 0;
    $weight_sum += $_ for @{$hash->{weights}};
    die 'GMM::from_hash: weights sum to zero' unless $weight_sum > 0;
    die 'GMM::from_hash: n_samples_fit must be a non-negative integer'
        unless defined($hash->{n_samples_fit}) && $hash->{n_samples_fit} =~ /^\d+$/;
    die 'GMM::from_hash: n_iter must be a non-negative integer'
        unless defined($hash->{n_iter}) && $hash->{n_iter} =~ /^\d+$/;
    die 'GMM::from_hash: log_likelihood must be finite'
        unless _finite($hash->{log_likelihood});
    $self->{n_features} = $hash->{n_features} + 0;
    $self->{n_samples_fit} = $hash->{n_samples_fit} + 0;
    $self->{means} = [ map { [ @$_ ] } @{$hash->{means}} ];
    $self->{variances} = [ map { [ @$_ ] } @{$hash->{variances}} ];
    $self->{weights} = [ @{$hash->{weights}} ];
    _normalize($self->{weights});
    $self->{converged} = $hash->{converged} ? 1 : 0;
    $self->{n_iter} = $hash->{n_iter} + 0;
    $self->{log_likelihood} = $hash->{log_likelihood} + 0;
    $self->{fitted} = 1;
    return $self;
}

sub n_components { return $_[0]->{n_components} }
sub means { return $_[0]->{means} }
sub variances { return $_[0]->{variances} }
sub weights { return $_[0]->{weights} }
sub converged { return $_[0]->{converged} }
sub n_iter { return $_[0]->{n_iter} }
sub log_likelihood { return $_[0]->{log_likelihood} }

sub _require_fitted { die 'GMM: fit must be called first' unless $_[0]->{fitted}; }

sub _initial_means {
    my ($points, $k) = @_;
    my @means = ([ @{$points->[0]} ]);
    while (@means < $k) {
        my ($best, $best_distance) = (0, -1);
        for my $i (0 .. $#$points) {
            my $distance = 9e99;
            for my $mean (@means) {
                my $candidate = _distance_squared($points->[$i], $mean);
                $distance = $candidate if $candidate < $distance;
            }
            if ($distance > $best_distance) {
                ($best, $best_distance) = ($i, $distance);
            }
        }
        push @means, [ @{$points->[$best]} ];
    }
    return \@means;
}

sub _global_variance {
    my ($points, $dimensions, $floor) = @_;
    my @mean = (0) x $dimensions;
    for my $point (@$points) {
        $mean[$_] += $point->[$_] for 0 .. $dimensions - 1;
    }
    $mean[$_] /= @$points for 0 .. $dimensions - 1;
    my @variance = (0) x $dimensions;
    for my $point (@$points) {
        $variance[$_] += ($point->[$_] - $mean[$_]) ** 2 for 0 .. $dimensions - 1;
    }
    for my $index (0 .. $dimensions - 1) {
        $variance[$index] = $variance[$index] / @$points;
        $variance[$index] = $floor if $variance[$index] < $floor;
    }
    return \@variance;
}

sub _e_step {
    my ($points, $weights, $means, $variances) = @_;
    my (@responsibilities, $log_likelihood) = ();
    for my $point (@$points) {
        my @log_probability = map {
            log($weights->[$_] || 1e-300) + _log_gaussian($point, $means->[$_], $variances->[$_])
        } 0 .. $#$means;
        my $normalizer = _log_sum_exp(\@log_probability);
        push @responsibilities, [ map { exp($_ - $normalizer) } @log_probability ];
        $log_likelihood += $normalizer;
    }
    return (\@responsibilities, $log_likelihood);
}

sub _log_gaussian {
    my ($point, $mean, $variance) = @_;
    my ($quadratic, $log_det) = (0, 0);
    for my $d (0 .. $#$point) {
        my $var = $variance->[$d] > 0 ? $variance->[$d] : 1e-300;
        $quadratic += ($point->[$d] - $mean->[$d]) ** 2 / $var;
        $log_det += log($var);
    }
    return -0.5 * (@$point * LOG_2PI + $log_det + $quadratic);
}

sub _farthest_point {
    my ($points, $means) = @_;
    my ($best, $best_distance) = (0, -1);
    for my $i (0 .. $#$points) {
        my $distance = 9e99;
        for my $mean (@$means) {
            my $candidate = _distance_squared($points->[$i], $mean);
            $distance = $candidate if $candidate < $distance;
        }
        ($best, $best_distance) = ($i, $distance) if $distance > $best_distance;
    }
    return $best;
}

sub _distance_squared {
    my ($left, $right) = @_;
    my $sum = 0;
    $sum += ($left->[$_] - $right->[$_]) ** 2 for 0 .. $#$left;
    return $sum;
}

sub _log_sum_exp {
    my ($values) = @_;
    my $max = $values->[0];
    for my $value (@$values) {
        $max = $value if $value > $max;
    }
    my $sum = 0;
    $sum += exp($_ - $max) for @$values;
    return $max + log($sum || 1e-300);
}

sub _argmax {
    my ($values) = @_;
    my $best = 0;
    for my $index (1 .. $#$values) {
        $best = $index if $values->[$index] > $values->[$best];
    }
    return $best;
}

sub _normalize {
    my ($values) = @_;
    my $sum = 0;
    $sum += $_ for @$values;
    if ($sum <= 0) {
        @$values = ((1 / @$values) x @$values);
    }
    else {
        $_ /= $sum for @$values;
    }
}

sub _validate_matrix {
    my ($points, $context, $expected_dimensions) = @_;
    die "$context: points must be a non-empty array reference"
        unless ref($points) eq 'ARRAY' && @$points;
    my $dimensions = defined $expected_dimensions ? $expected_dimensions : scalar @{$points->[0] // []};
    die "$context: points must have at least one feature" unless $dimensions > 0;
    for my $row (@$points) {
        die "$context: inconsistent feature dimensions"
            unless ref($row) eq 'ARRAY' && @$row == $dimensions;
        for my $value (@$row) {
            die "$context: points contain a non-finite value" unless _finite($value);
        }
    }
}

sub _unique_point_count {
    my ($points) = @_;
    my %seen;
    $seen{join "\x1e", map { sprintf '%.15g', $_ } @$_} = 1 for @$points;
    return scalar keys %seen;
}

sub _finite { return defined $_[0] && $_[0] =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/ && $_[0] == $_[0] && abs($_[0]) <= 1e300; }
sub _positive { return _finite($_[0]) && $_[0] > 0; }

1;
