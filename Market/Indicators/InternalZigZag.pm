package Market::Indicators::InternalZigZag;

use strict;
use warnings;

# Causal internal ZigZag.  A pivot centred on bar N is only made available
# after its right-hand confirmation window has closed at N + pivot_length.

sub new {
    my ($class, %args) = @_;

    my $pivot_length   = $args{pivot_length}   // 5;
    my $min_leg_bars   = $args{min_leg_bars}   // 4;
    my $atr_multiplier = $args{atr_multiplier} // 1.0;
    my $min_price_move = $args{min_price_move} // 0;

    die 'InternalZigZag::new: pivot_length must be a positive integer'
        unless defined $pivot_length && $pivot_length =~ /^\d+$/ && $pivot_length > 0;
    die 'InternalZigZag::new: min_leg_bars must be a non-negative integer'
        unless defined $min_leg_bars && $min_leg_bars =~ /^\d+$/;
    die 'InternalZigZag::new: atr_multiplier must be non-negative'
        unless _non_negative_number($atr_multiplier);
    die 'InternalZigZag::new: min_price_move must be non-negative'
        unless _non_negative_number($min_price_move);

    return bless {
        pivot_length    => $pivot_length + 0,
        min_leg_bars    => $min_leg_bars + 0,
        atr_multiplier  => $atr_multiplier + 0,
        min_price_move  => $min_price_move + 0,
        _atr_ref         => $args{atr_indicator},
        _result          => undef,
    }, $class;
}

sub set_atr_indicator { $_[0]->{_atr_ref} = $_[1]; return $_[0]; }

sub reset { $_[0]->{_result} = undef; }

sub compute_all {
    my ($self, $market) = @_;
    die 'InternalZigZag::compute_all: market data is required'
        unless $market && $market->can('_active_array');
    my $candles = $market->_active_array();
    my $atr = $self->{_atr_ref} && $self->{_atr_ref}->can('get_values')
        ? $self->{_atr_ref}->get_values() : [];
    $self->{_result} = @$candles
        ? $self->compute(candles => $candles, atr_series => $atr)
        : { pivots => [], debug_pivots => [], segments => [], active_segment => undef,
            trend => undef, max_visible_index => -1, replay_safe => 1 };
    return $self->{_result};
}

sub update_last { return $_[0]->compute_all($_[1]); }
sub get_result { return $_[0]->{_result}; }
sub get_pivots { return $_[0]->{_result}{pivots} // []; }
sub get_segments { return $_[0]->{_result}{segments} // []; }
sub get_active_segment { return $_[0]->{_result}{active_segment}; }
sub get_values { return []; }

sub compute {
    my ($class_or_self, %args) = @_;
    my $candles = $args{candles};
    die 'InternalZigZag::compute: candles must be a non-empty array reference'
        unless ref($candles) eq 'ARRAY' && @$candles;

    my $self = ref($class_or_self) ? $class_or_self : $class_or_self->new(%args);
    my $max_idx = defined $args{max_visible_index} ? $args{max_visible_index} : $#$candles;
    die 'InternalZigZag::compute: max_visible_index must be a non-negative integer'
        unless defined $max_idx && $max_idx =~ /^\d+$/;
    $max_idx = $#$candles if $max_idx > $#$candles;

    _validate_candles($candles, $max_idx);
    my $atr = $args{atr_series} // [];
    die 'InternalZigZag::compute: atr_series must be an array reference'
        unless ref($atr) eq 'ARRAY';
    _validate_atr($atr, $max_idx);

    my @pivots;
    my $len = $self->{pivot_length};
    for my $confirm_idx (0 .. $max_idx) {
        my $center = $confirm_idx - $len;
        next if $center < $len;
        next if $center + $len > $max_idx;

        my ($is_high, $is_low) = $self->_confirmed_pivot_flags($candles, $center);
        next unless $is_high || $is_low;

        for my $candidate ($self->_ordered_candidates(
            $candles, $atr, $center, $confirm_idx, $is_high, $is_low, \@pivots,
        )) {
            $self->_apply_candidate(\@pivots, $candidate);
        }
    }

    my ($segments, $active_segment) = _segments_from_pivots(\@pivots);
    return {
        timeframe         => $args{timeframe} // '1m',
        max_visible_index => $max_idx,
        pivot_length      => $self->{pivot_length},
        min_leg_bars      => $self->{min_leg_bars},
        atr_multiplier    => $self->{atr_multiplier},
        min_price_move    => $self->{min_price_move},
        pivots            => [ map { { %$_ } } @pivots ],
        debug_pivots      => [ map { _debug_pivot($_) } @pivots ],
        segments          => $segments,
        active_segment    => $active_segment,
        trend             => $active_segment ? $active_segment->{direction} : undef,
        replay_safe       => 1,
    };
}

sub debug_pivots {
    my ($class_or_self, %args) = @_;
    return $class_or_self->compute(%args)->{debug_pivots};
}

sub _confirmed_pivot_flags {
    my ($self, $candles, $center) = @_;
    my $len = $self->{pivot_length};
    my ($is_high, $is_low) = (1, 1);
    my ($high, $low) = @{$candles->[$center]}{qw(high low)};

    for my $i ($center - $len .. $center + $len) {
        next if $i == $center;
        my $c = $candles->[$i];
        $is_high = 0 if $c->{high} > $high || ($c->{high} == $high && $i > $center);
        $is_low  = 0 if $c->{low}  < $low  || ($c->{low}  == $low  && $i > $center);
        last if !$is_high && !$is_low;
    }
    return ($is_high, $is_low);
}

sub _ordered_candidates {
    my ($self, $candles, $atr, $center, $confirm_idx, $is_high, $is_low, $pivots) = @_;
    my $high = $is_high ? $self->_candidate('HIGH', $candles, $atr, $center, $confirm_idx) : undef;
    my $low  = $is_low  ? $self->_candidate('LOW',  $candles, $atr, $center, $confirm_idx) : undef;
    return grep { defined } ($high, $low) unless $high && $low;

    my $last_type = @$pivots ? $pivots->[-1]{type} : undef;
    return ($low, $high) if ($last_type // '') eq 'HIGH';
    return ($high, $low) if ($last_type // '') eq 'LOW';
    my $c = $candles->[$center];
    return $c->{close} >= $c->{open} ? ($low, $high) : ($high, $low);
}

sub _candidate {
    my ($self, $type, $candles, $atr, $center, $confirm_idx) = @_;
    my $c = $candles->[$center];
    my $confirmation = $candles->[$confirm_idx];
    return {
        type           => $type,
        kind           => lc($type),
        index          => $center,
        time           => $c->{time},
        price          => ($type eq 'HIGH' ? $c->{high} : $c->{low}) + 0,
        confirmed      => 1,
        confirmed_at   => $confirm_idx,
        confirmed_time => $confirmation->{time},
        pivot_length   => $self->{pivot_length},
        atr            => defined $atr->[$center] ? $atr->[$center] + 0 : undef,
    };
}

sub _apply_candidate {
    my ($self, $pivots, $candidate) = @_;
    return unless $candidate;
    if (!@$pivots) {
        push @$pivots, $candidate;
        return;
    }

    my $last = $pivots->[-1];
    if ($candidate->{type} eq $last->{type}) {
        $pivots->[-1] = $candidate if _more_extreme($candidate, $last);
        return;
    }
    return if $candidate->{index} <= $last->{index};
    return if $candidate->{index} - $last->{index} < $self->{min_leg_bars};
    return if abs($candidate->{price} - $last->{price}) < $self->_min_move($candidate, $last);
    push @$pivots, $candidate;
}

sub _min_move {
    my ($self, $candidate, $last) = @_;
    my @atrs = grep { defined } ($candidate->{atr}, $last->{atr});
    my $sum = 0;
    $sum += $_ for @atrs;
    my $atr = @atrs ? $sum / @atrs : 0;
    my $atr_move = $atr * $self->{atr_multiplier};
    return $atr_move > $self->{min_price_move} ? $atr_move : $self->{min_price_move};
}

sub _more_extreme {
    my ($candidate, $last) = @_;
    return $candidate->{price} > $last->{price} if $candidate->{type} eq 'HIGH';
    return $candidate->{price} < $last->{price};
}

sub _segments_from_pivots {
    my ($pivots) = @_;
    return ([], undef) if @$pivots < 2;
    my @segments;
    for my $i (1 .. $#$pivots) {
        my $segment = _segment_from_pair($pivots->[$i - 1], $pivots->[$i]);
        return (\@segments, $segment) if $i == $#$pivots;
        push @segments, $segment;
    }
    return (\@segments, undef);
}

sub _segment_from_pair {
    my ($start, $end) = @_;
    my $direction = $start->{type} eq 'LOW' && $end->{type} eq 'HIGH' ? 'bullish' : 'bearish';
    return {
        direction       => $direction,
        start_kind      => $start->{kind}, start_index => $start->{index},
        start_time      => $start->{time}, start_price => $start->{price},
        end_kind        => $end->{kind},   end_index   => $end->{index},
        end_time        => $end->{time},   end_price   => $end->{price},
        created_at      => $end->{confirmed_at}, created_time => $end->{confirmed_time},
        updated_at      => $end->{confirmed_at}, updated_time => $end->{confirmed_time},
        repaint_updates => 0,
        completed_at    => $end->{confirmed_at}, completed_time => $end->{confirmed_time},
    };
}

sub _debug_pivot {
    my ($pivot) = @_;
    return { map { $_ => $pivot->{$_} } qw(index time type price confirmed confirmed_at confirmed_time) };
}

sub _validate_candles {
    my ($candles, $max_idx) = @_;
    for my $i (0 .. $max_idx) {
        my $c = $candles->[$i];
        die "InternalZigZag::compute: candle $i must be a hash reference" unless ref($c) eq 'HASH';
        for my $field (qw(open high low close)) {
            die "InternalZigZag::compute: candle $i missing numeric $field"
                unless _number($c->{$field});
        }
        die "InternalZigZag::compute: candle $i has high below low"
            if $c->{high} < $c->{low};
        die "InternalZigZag::compute: candle $i has OHLC outside high/low"
            if $c->{open} < $c->{low} || $c->{open} > $c->{high}
                || $c->{close} < $c->{low} || $c->{close} > $c->{high};
    }
}

sub _validate_atr {
    my ($atr, $max_idx) = @_;
    for my $i (0 .. $max_idx) {
        next unless defined $atr->[$i];
        die "InternalZigZag::compute: atr_series[$i] must be non-negative numeric"
            unless _non_negative_number($atr->[$i]);
    }
}

sub _number {
    return defined($_[0]) && !ref($_[0])
        && "$_[0]" =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/
        && $_[0] == $_[0] && abs($_[0]) <= 1e300;
}
sub _non_negative_number { return _number($_[0]) && $_[0] >= 0; }

1;
