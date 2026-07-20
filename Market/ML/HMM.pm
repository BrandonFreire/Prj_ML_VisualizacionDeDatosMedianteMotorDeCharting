package Market::ML::HMM;

use strict;
use warnings;

# Discrete transition HMM with externally supplied continuous log-emissions.
# `forward_filter` is the production decoder: every state at t is conditioned
# only on observations through t.  Viterbi remains available for retrospective
# diagnostics but must not be used to label historical backtests.

sub new {
    my ($class, %args) = @_;
    my $states = $args{states} // ['S0', 'S1', 'S2'];
    die 'HMM::new: states must be a non-empty array reference'
        unless ref($states) eq 'ARRAY' && @$states;
    my $n = @$states;
    my $pi = $args{pi} // [ (1 / $n) x $n ];
    my $transition = $args{A} // $args{transition_matrix};
    $transition //= [ map { [ (1 / $n) x $n ] } 1 .. $n ];
    _validate_probability_vector($pi, $n, 'HMM::new pi');
    _validate_probability_matrix($transition, $n, 'HMM::new transition matrix');
    my @normalized_pi = @$pi;
    _normalize(\@normalized_pi);
    my @normalized_a = map { my @row = @$_; _normalize(\@row); \@row } @$transition;
    return bless {
        states => [ @$states ], n_states => $n, pi => \@normalized_pi,
        A => \@normalized_a,
    }, $class;
}

sub n_states { return $_[0]->{n_states} }
sub states { return $_[0]->{states} }
sub pi { return $_[0]->{pi} }
sub transition_matrix { return $_[0]->{A} }

sub estimate_transition_matrix {
    my ($class_or_self, $sequence, %args) = @_;
    die 'HMM::estimate_transition_matrix: sequence must be an array reference'
        unless ref($sequence) eq 'ARRAY';
    my $n = $args{n_states} // (ref($class_or_self) ? $class_or_self->{n_states} : undef);
    die 'HMM::estimate_transition_matrix: n_states must be positive' unless $n && $n =~ /^\d+$/;
    my $laplace = $args{laplace_alpha} // 1;
    my $sticky = $args{sticky_bias} // 0.05;
    die 'HMM::estimate_transition_matrix: smoothing values must be non-negative'
        unless _non_negative($laplace) && _non_negative($sticky);
    my @counts = map { [ ($laplace) x $n ] } 1 .. $n;
    $counts[$_][$_] += $sticky for 0 .. $n - 1;
    for my $i (1 .. $#$sequence) {
        my ($from, $to) = @{$sequence}[$i - 1, $i];
        next unless defined $from && defined $to && $from =~ /^\d+$/ && $to =~ /^\d+$/
            && $from < $n && $to < $n;
        $counts[$from][$to]++;
    }
    for my $row (@counts) { _normalize($row); }
    return \@counts;
}

sub estimate_initial_distribution {
    my ($class_or_self, %args) = @_;
    my $source = $args{initial_responsibilities} // $args{weights} // $args{gmm_weights};
    if (ref($source) eq 'ARRAY' && @$source) {
        my @result = @$source;
        _validate_probability_vector(\@result, scalar @result, 'HMM::estimate_initial_distribution');
        _normalize(\@result);
        return \@result;
    }
    my $n = $args{n_states} // (ref($class_or_self) ? $class_or_self->{n_states} : undef);
    die 'HMM::estimate_initial_distribution: n_states must be positive' unless $n && $n =~ /^\d+$/;
    return [ (1 / $n) x $n ];
}

sub forward_filter {
    my ($self, $log_emissions, %args) = @_;
    _validate_log_emissions($log_emissions, $self->{n_states}, 'HMM::forward_filter');
    my $posterior = $args{initial_posterior};
    if ($posterior) {
        _validate_probability_vector($posterior, $self->{n_states}, 'HMM::forward_filter initial_posterior');
        $posterior = [ @$posterior ];
        _normalize($posterior);
    }
    my (@posteriors, @indices, @names);
    my $log_likelihood = 0;
    for my $time (0 .. $#$log_emissions) {
        my ($next, $increment) = $self->forward_step(
            posterior => $posterior, log_emission => $log_emissions->[$time],
            initial => !$posterior,
        );
        $posterior = $next;
        $log_likelihood += $increment;
        my $state = _argmax($posterior);
        push @posteriors, [ @$posterior ];
        push @indices, $state;
        push @names, $self->{states}[$state];
    }
    return {
        posteriors => \@posteriors, state_indices => \@indices, state_names => \@names,
        final_posterior => $posterior ? [ @$posterior ] : undef,
        log_likelihood => $log_likelihood + 0, replay_safe => 1,
    };
}

sub forward_step {
    my ($self, %args) = @_;
    my $emission = $args{log_emission};
    _validate_log_emissions([$emission], $self->{n_states}, 'HMM::forward_step');
    my $prior;
    if ($args{initial}) {
        $prior = [ @{$self->{pi}} ];
    }
    else {
        my $previous = $args{posterior};
        _validate_probability_vector($previous, $self->{n_states}, 'HMM::forward_step posterior');
        $prior = _transition($previous, $self->{A});
    }
    my @log_values = map {
        log($prior->[$_] || 1e-300) + $emission->[$_]
    } 0 .. $self->{n_states} - 1;
    my $normalizer = _log_sum_exp(\@log_values);
    my @posterior = map { exp($_ - $normalizer) } @log_values;
    _normalize(\@posterior);
    return (\@posterior, $normalizer);
}

sub viterbi {
    my ($self, $log_emissions) = @_;
    _validate_log_emissions($log_emissions, $self->{n_states}, 'HMM::viterbi');
    my $n = $self->{n_states};
    my @delta;
    my @backpointer;
    $delta[0] = [ map { log($self->{pi}[$_] || 1e-300) + $log_emissions->[0][$_] } 0 .. $n - 1 ];
    $backpointer[0] = [ (0) x $n ];
    for my $time (1 .. $#$log_emissions) {
        for my $state (0 .. $n - 1) {
            my ($best, $value) = (0, -1e300);
            for my $previous (0 .. $n - 1) {
                my $candidate = $delta[$time - 1][$previous] + log($self->{A}[$previous][$state] || 1e-300);
                if ($candidate > $value) { ($best, $value) = ($previous, $candidate); }
            }
            $delta[$time][$state] = $value + $log_emissions->[$time][$state];
            $backpointer[$time][$state] = $best;
        }
    }
    my $last = _argmax($delta[-1]);
    my @path = ($last);
    for (my $time = $#$log_emissions; $time > 0; $time--) {
        unshift @path, $backpointer[$time][$path[0]];
    }
    return {
        state_indices => \@path, state_names => [ map { $self->{states}[$_] } @path ],
        log_probability => $delta[-1][$last] + 0, replay_safe => 0,
    };
}

sub log_emissions_from_discrete {
    my ($class_or_self, $emission_matrix, $observations) = @_;
    die 'HMM::log_emissions_from_discrete: observations must be an array reference'
        unless ref($observations) eq 'ARRAY';
    die 'HMM::log_emissions_from_discrete: emission matrix must be a non-empty array reference'
        unless ref($emission_matrix) eq 'ARRAY' && @$emission_matrix;
    my @out;
    for my $observation (@$observations) {
        die 'HMM::log_emissions_from_discrete: invalid observation index'
            unless defined $observation && $observation =~ /^\d+$/;
        push @out, [ map {
            my $probability = $_->[$observation] // 0;
            log($probability > 0 ? $probability : 1e-300)
        } @$emission_matrix ];
    }
    return \@out;
}

sub to_hash {
    my ($self) = @_;
    return {
        states => [ @{$self->{states}} ], pi => [ @{$self->{pi}} ],
        A => [ map { [ @$_ ] } @{$self->{A}} ],
    };
}

sub from_hash {
    my ($class, $hash) = @_;
    die 'HMM::from_hash: invalid model' unless ref($hash) eq 'HASH';
    return $class->new(states => $hash->{states}, pi => $hash->{pi}, A => $hash->{A});
}

sub _transition {
    my ($posterior, $matrix) = @_;
    my @next = (0) x @$posterior;
    for my $from (0 .. $#$posterior) {
        $next[$_] += $posterior->[$from] * $matrix->[$from][$_] for 0 .. $#$posterior;
    }
    _normalize(\@next);
    return \@next;
}

sub _validate_log_emissions {
    my ($emissions, $states, $context) = @_;
    die "$context: log emissions must be a non-empty array reference"
        unless ref($emissions) eq 'ARRAY' && @$emissions;
    for my $row (@$emissions) {
        die "$context: invalid log emission row"
            unless ref($row) eq 'ARRAY' && @$row == $states;
        for my $value (@$row) {
            die "$context: log emissions must be finite" unless _finite($value);
        }
    }
}

sub _validate_probability_vector {
    my ($values, $expected, $context) = @_;
    die "$context: invalid probability vector"
        unless ref($values) eq 'ARRAY' && @$values == $expected;
    for my $value (@$values) {
        die "$context: probabilities must be finite and non-negative"
            unless _non_negative($value);
    }
    my $sum = 0; $sum += $_ for @$values;
    die "$context: probability vector sums to zero" unless $sum > 0;
}

sub _validate_probability_matrix {
    my ($matrix, $states, $context) = @_;
    die "$context: invalid probability matrix"
        unless ref($matrix) eq 'ARRAY' && @$matrix == $states;
    _validate_probability_vector($_, $states, $context) for @$matrix;
}

sub _normalize {
    my ($values) = @_;
    my $sum = 0; $sum += $_ for @$values;
    if ($sum <= 0) { @$values = ((1 / @$values) x @$values); }
    else { $_ /= $sum for @$values; }
}

sub _argmax {
    my ($values) = @_;
    my $best = 0;
    for my $index (1 .. $#$values) { $best = $index if $values->[$index] > $values->[$best]; }
    return $best;
}

sub _log_sum_exp {
    my ($values) = @_;
    my $max = $values->[0];
    for my $value (@$values) { $max = $value if $value > $max; }
    my $sum = 0; $sum += exp($_ - $max) for @$values;
    return $max + log($sum || 1e-300);
}

sub _finite { return defined $_[0] && $_[0] =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][+-]?\d+)?$/ && $_[0] == $_[0] && abs($_[0]) <= 1e300; }
sub _non_negative { return _finite($_[0]) && $_[0] >= 0; }

1;
