package Market::Indicators::PivotMissedReversal;

use strict;
use warnings;


sub new {
    my ($class, %args) = @_;
    return bless {
        length       => _length($args{length} // $args{pivot_length} // 50),
        show_regular => exists $args{show_regular} ? ($args{show_regular} ? 1 : 0) : 1,
        show_missed  => exists $args{show_missed}  ? ($args{show_missed}  ? 1 : 0) : 1,
        _candles     => undef,
        _regular     => [],
        _missed      => [],
        _levels      => [],
        _ambiguous   => [],
        _provisional => undef,
        _trace_events => [],
        _ghost_anchors => [],
        _current_ghost => undef,
        _max_visible_index => -1,
    }, $class;
}

sub reset {
    my ($self) = @_;
    $self->{_regular} = [];
    $self->{_missed}  = [];
    $self->{_levels}  = [];
    $self->{_ambiguous} = [];
    $self->{_provisional} = undef;
    $self->{_trace_events} = [];
    $self->{_ghost_anchors} = [];
    $self->{_current_ghost} = undef;
    $self->{_candles} = undef;
    $self->{_max_visible_index} = -1;
    return;
}

sub compute_all {
    my ($self, $market) = @_;
    my $candles = $market ? $market->get_active_candles() : [];
    return $self->compute(candles => $candles);
}

sub compute {
    my ($class_or_self, %args) = @_;
    my $candles = $args{candles} // [];
    die 'PivotMissedReversal::compute: candles debe ser un arrayref'
        unless ref($candles) eq 'ARRAY';
    my $self = ref($class_or_self) ? $class_or_self : $class_or_self->new(%args);
    $self->reset();
    $self->{length} = _length($args{length} // $args{pivot_length})
        if defined($args{length}) || defined($args{pivot_length});
    $self->{show_regular} = $args{show_regular} ? 1 : 0 if exists $args{show_regular};
    $self->{show_missed}  = $args{show_missed}  ? 1 : 0 if exists $args{show_missed};

    die 'PivotMissedReversal::compute: max_visible_index debe ser un entero'
        if defined($args{max_visible_index}) && $args{max_visible_index} !~ /^-?\d+$/;
    my $max_idx = defined($args{max_visible_index})
        ? int($args{max_visible_index}) : $#$candles;
    $max_idx = $#$candles if $max_idx > $#$candles;
    $self->{_max_visible_index} = $max_idx;
    return $self->_result(-1) if $max_idx < 0;
    my @series = map { { %{ $candles->[$_] } } } 0 .. $max_idx;
    _validate_candles(\@series);
    $self->{_candles} = \@series;

    my $length = $self->{length};
    my ($tracked_max, $tracked_min, $tracked_max_i, $tracked_min_i);
    my ($follow_max, $follow_min, $follow_max_i, $follow_min_i);
    my ($last_type, $last_index, $last_price);

    for my $n (0 .. $max_idx) {
        my $center = $n - $length;
        next if $center < 0;
        my $candle = $series[$center];
        my ($high, $low) = @{$candle}{qw(high low)};

        if (!defined($tracked_max) || $high > $tracked_max) {
            ($tracked_max, $tracked_max_i) = ($high, $center);
            ($follow_min, $follow_min_i) = ($low, $center);
        }
        if (!defined($tracked_min) || $low < $tracked_min) {
            ($tracked_min, $tracked_min_i) = ($low, $center);
            ($follow_max, $follow_max_i) = ($high, $center);
        }
        if (!defined($follow_min) || $low < $follow_min) {
            ($follow_min, $follow_min_i) = ($low, $center);
        }
        if (!defined($follow_max) || $high > $follow_max) {
            ($follow_max, $follow_max_i) = ($high, $center);
        }
        next if $center < $length;

        my $pivot_high = _is_pivot($self->{_candles}, $center, $length, 'high');
        my $pivot_low  = _is_pivot($self->{_candles}, $center, $length, 'low');
        if ($pivot_high && $pivot_low) {
            my $resolution = !defined($last_type) ? 'skipped_without_context'
                : $last_type eq 'high' ? 'low_after_high'
                : 'high_after_low';
            push @{ $self->{_ambiguous} }, {
                index => $center, time => $candle->{time}, confirmed_at => $n,
                confirmed_time => $series[$n]{time}, resolution => $resolution,
                replay_safe => 1,
            };
            if (!defined $last_type) {
                ($pivot_high, $pivot_low) = (0, 0);
            }
            elsif ($last_type eq 'high') {
                $pivot_high = 0;
            }
            else {
                $pivot_low = 0;
            }
        }

        if ($pivot_high) {
            if ($self->{show_missed} && defined $last_type) {
                if ($last_type eq 'high') {
                    $self->_add_missed('low', $tracked_min_i, $tracked_min, $n,
                        'consecutive_confirmed_highs');
                }
                elsif (defined($tracked_max) && $high < $tracked_max) {
                    $self->_add_missed('high', $tracked_max_i, $tracked_max, $n,
                        'higher_extreme_before_lower_high');
                    $self->_add_missed('low', $follow_min_i, $follow_min, $n,
                        'opposite_extreme_after_higher_high');
                }
            }
            elsif ($self->{show_missed} && defined($tracked_max) && $high < $tracked_max) {
                $self->_add_missed('high', $tracked_max_i, $tracked_max, $n,
                    'initial_higher_extreme_before_first_high');
                $self->_add_missed('low', $follow_min_i, $follow_min, $n,
                    'initial_opposite_extreme_after_higher_high');
            }
            $self->_add_regular('high', $center, $high, $n) if $self->{show_regular};
            ($last_type, $last_index, $last_price) = ('high', $center, $high);
            ($tracked_max, $tracked_min, $tracked_max_i, $tracked_min_i) = ($high, $high, $center, $center);
            ($follow_max, $follow_min, $follow_max_i, $follow_min_i) = ($high, $high, $center, $center);
        }
        elsif ($pivot_low) {
            if ($self->{show_missed} && defined $last_type) {
                if ($last_type eq 'low') {
                    $self->_add_missed('high', $tracked_max_i, $tracked_max, $n,
                        'consecutive_confirmed_lows');
                }
                elsif (defined($tracked_min) && $low > $tracked_min) {
                    $self->_add_missed('low', $tracked_min_i, $tracked_min, $n,
                        'lower_extreme_before_higher_low');
                    $self->_add_missed('high', $follow_max_i, $follow_max, $n,
                        'opposite_extreme_after_lower_low');
                }
            }
            elsif ($self->{show_missed} && defined $tracked_max) {
                $self->_add_missed('high', $tracked_max_i, $tracked_max, $n,
                    'initial_high_before_first_low');
            }
            $self->_add_regular('low', $center, $low, $n) if $self->{show_regular};
            ($last_type, $last_index, $last_price) = ('low', $center, $low);
            ($tracked_max, $tracked_min, $tracked_max_i, $tracked_min_i) = ($low, $low, $center, $center);
            ($follow_max, $follow_min, $follow_max_i, $follow_min_i) = ($low, $low, $center, $center);
        }
    }
    my ($trace_events, $ghost_anchors, $current_ghost) =
        _reference_trace_replay(\@series, $length, $max_idx);
    $self->{_trace_events} = $trace_events;
    $self->{_ghost_anchors} = $ghost_anchors;
    $self->{_current_ghost} = $current_ghost;

    return $self->_result($max_idx, $last_type, $last_index, $last_price);
}

sub _add_regular {
    my ($self, $type, $index, $price, $confirmed_at) = @_;
    push @{ $self->{_regular} }, {
        id           => join('_', 'regular', $type, $index, $confirmed_at),
        kind         => 'regularPivot', status => 'confirmed', confirmed => 1,
        source       => 'regular', type => $type, pivotType => $type, index => $index,
        time         => $self->{_candles}[$index]{time}, price => $price + 0,
        pivotTime    => $self->{_candles}[$index]{time},
        confirmationIndex => $confirmed_at,
        confirmationTime => $self->{_candles}[$confirmed_at]{time},
        confirmed_at => $confirmed_at,
        confirmed_time => $self->{_candles}[$confirmed_at]{time},
        label        => $type eq 'high' ? "\x{25BC}" : "\x{25B2}",
        replay_safe  => 1,
    };
}

sub _add_missed {
    my ($self, $type, $index, $price, $confirmed_at, $reason) = @_;
    return unless defined($index) && defined($price) && $index >= 0;
    return if $index >= $confirmed_at;
    my $key = join(':', $type, $index, $confirmed_at);
    return if grep { ($_->{_key} // '') eq $key } @{ $self->{_missed} };
    if (my $active = $self->{_levels}[-1]) {
        $active->{active} = 0;
        $active->{end_index} = $confirmed_at;
    }
    my $id = join('_', 'missed', $type, $index, $confirmed_at, scalar @{ $self->{_missed} });
    my $event = {
        _key         => $key,
        id           => $id, kind => 'missedPivot', status => 'confirmed', confirmed => 1,
        eventType    => $type eq 'high' ? 'missedPivotHigh' : 'missedPivotLow',
        source       => 'missed', type => $type, pivotType => $type,
        index        => $index, time => $self->{_candles}[$index]{time},
        price        => $price + 0, confirmed_at => $confirmed_at,
        pivotTime    => $self->{_candles}[$index]{time},
        confirmationIndex => $confirmed_at,
        confirmationTime => $self->{_candles}[$confirmed_at]{time},
        confirmed_time => $self->{_candles}[$confirmed_at]{time},
        reason       => $reason, label => "\x{1F47B}", replay_safe => 1,
    };
    push @{ $self->{_missed} }, $event;
    push @{ $self->{_levels} }, {
        id => "level_$id", source => 'missed_reversal_level', type => $type,
        price => $price + 0, start_index => $index, end_index => $confirmed_at,
        created_at => $confirmed_at, active => 1, event_id => $id,
        replay_safe => 1,
    };
}

sub _result {
    my ($self, $max_idx, $last_type, $last_index, $last_price) = @_;
    $last_type  //= @{ $self->{_regular} } ? $self->{_regular}[-1]{type}  : undef;
    $last_index //= @{ $self->{_regular} } ? $self->{_regular}[-1]{index} : undef;
    $last_price //= @{ $self->{_regular} } ? $self->{_regular}[-1]{price} : undef;
    my $provisional;
    if (defined($last_type) && defined($last_index) && $last_index < $max_idx) {
        my $type = $last_type eq 'high' ? 'low' : 'high';
        my ($best_index, $best_price);
        for my $i ($last_index + 1 .. $max_idx) {
            my $price = $self->{_candles}[$i]{$type};
            if (!defined($best_price)
                || ($type eq 'high' ? $price > $best_price : $price < $best_price)) {
                ($best_index, $best_price) = ($i, $price);
            }
        }
        $provisional = {
            source => 'provisional', type => $type, index => $best_index,
            time => $self->{_candles}[$best_index]{time}, price => $best_price + 0,
            from_index => $last_index, from_price => $last_price + 0,
            status => 'temporary', confirmed => 0, replay_safe => 1,
        } if defined $best_index;
    }
    $self->{_provisional} = $provisional ? { %$provisional } : undef;
    return {
        pivot_length       => $self->{length},
        max_visible_index  => $max_idx,
        regular_pivots     => [ map { { %$_ } } @{ $self->{_regular} } ],
        missed_pivots      => [ map { my %copy = %$_; delete $copy{_key}; \%copy } @{ $self->{_missed} } ],
        reversal_levels    => [ map {
            my %copy = %$_;
            $copy{end_index} = $max_idx if $copy{active};
            \%copy;
        } @{ $self->{_levels} } ],
        ambiguous_pivots   => [ map { { %$_ } } @{ $self->{_ambiguous} } ],
        provisional_pivot  => $provisional,
        trace_events       => [ map { { %$_ } } @{ $self->{_trace_events} } ],
        ghost_anchors      => [ map { { %$_ } } @{ $self->{_ghost_anchors} } ],
        current_ghost      => $self->{_current_ghost}
            ? { %{ $self->{_current_ghost} } } : undef,
        replay_safe        => 1,
    };
}

sub _is_pivot {
    my ($candles, $center, $length, $kind) = @_;
    my $price = $candles->[$center]{$kind};
    for my $i ($center - $length .. $center + $length) {
        next if $i == $center;
        my $other = $candles->[$i]{$kind};
        return 0 if $kind eq 'high'
            ? ($other > $price || ($other == $price && $i > $center))
            : ($other < $price || ($other == $price && $i > $center));
    }
    return 1;
}

sub _validate_candles {
    my ($candles) = @_;
    for my $i (0 .. $#$candles) {
        die "PivotMissedReversal: vela $i invalida" unless ref($candles->[$i]) eq 'HASH';
        die "PivotMissedReversal: vela $i sin high numerico finito"
            unless _finite($candles->[$i]{high});
        die "PivotMissedReversal: vela $i sin low numerico finito"
            unless _finite($candles->[$i]{low});
        die "PivotMissedReversal: vela $i con high menor que low"
            if $candles->[$i]{high} < $candles->[$i]{low};
    }
}

sub _length {
    my ($length) = @_;
    $length = 50 unless defined($length) && $length =~ /^\d+$/;
    $length = int($length);
    $length = 1 if $length < 1;
    $length = 500 if $length > 500;
    return $length;
}

sub get_regular_pivots  { return $_[0]->{_regular} }
sub get_missed_pivots   { return $_[0]->{_missed}  }
sub get_trace_events    { return $_[0]->{_trace_events} }
sub get_ghost_anchors   {
    return [ map { { %$_ } } @{ $_[0]->{_ghost_anchors} // [] } ];
}
sub get_current_ghost {
    my ($self) = @_;
    return $self->{_current_ghost} ? { %{ $self->{_current_ghost} } } : undef;
}
sub get_reversal_levels {
    my ($self) = @_;
    my $max_idx = $self->{_max_visible_index} // -1;
    return [ map {
        my %copy = %$_;
        $copy{end_index} = $max_idx if $copy{active} && $max_idx >= 0;
        \%copy;
    } @{ $self->{_levels} } ];
}

sub get_provisional_pivot {
    my ($self) = @_;
    return $self->{_provisional} ? { %{ $self->{_provisional} } } : undef;
}

sub get_provisional_pivot_at {
    my ($self, $current_bar) = @_;
    my $candles = $self->{_candles} // [];
    return undef unless @$candles;
    $current_bar = $self->{_max_visible_index} unless defined $current_bar;
    return undef unless defined($current_bar) && $current_bar =~ /^\d+$/;
    $current_bar = int($current_bar);
    $current_bar = $#$candles if $current_bar > $#$candles;
    return undef if $current_bar < 0;

    my $anchor;
    for my $candidate (@{ $self->{_ghost_anchors} // [] }) {
        last if ($candidate->{confirmed_at} // 0) > $current_bar;
        $anchor = $candidate;
    }
    return undef unless $anchor && $anchor->{index} < $current_bar;

    my $type = $anchor->{os} == 1 ? 'low' : 'high';
    my ($best_index, $best_price) = _latest_extreme(
        $candles, $anchor->{index} + 1, $current_bar, $type,
    );
    return undef unless defined $best_index;
    my %result = (
        id => join('_', 'provisional', $type, $best_index),
        kind => 'provisionalPivot', source => 'provisional',
        type => $type, pivotType => $type,
        index => $best_index, time => $candles->[$best_index]{time},
        price => $best_price + 0,
        from_index => $anchor->{index},
        status => 'temporary', confirmed => 0, provisional => 1,
        max_visible_index => $current_bar, label => "\x{1F47B}", replay_safe => 1,
    );
    $result{from_price} = $anchor->{price} + 0
        if defined $anchor->{price};
    return \%result;
}

sub _reference_trace_replay {
    my ($candles, $length, $max_idx) = @_;
    my @anchors = ({
        confirmed_at => 0, index => 0, os => 0,
        type => 'initial', price => undef,
    });
    my (@events, $active);
    my ($anchor_index, $anchor_price, $os) = (0, undef, 0);

    for my $event_index (0 .. $max_idx) {
        my ($pivot_high, $pivot_low, $center) = (0, 0, $event_index - $length);
        if ($center >= $length) {
            $pivot_high = _is_pivot($candles, $center, $length, 'high');
            $pivot_low  = _is_pivot($candles, $center, $length, 'low');
        }

        my $new_anchor = $pivot_high || $pivot_low;
        if ($pivot_high) {
            ($anchor_index, $anchor_price, $os) =
                ($center, $candles->[$center]{high} + 0, 1);
        }
        if ($pivot_low) {
            ($anchor_index, $anchor_price, $os) =
                ($center, $candles->[$center]{low} + 0, 0);
        }
        if ($new_anchor) {
            push @anchors, {
                confirmed_at => $event_index, index => $anchor_index,
                os => $os, type => $os == 1 ? 'high' : 'low',
                price => $anchor_price,
            };
        }

        my $ghost_type = $os == 1 ? 'low' : 'high';
        if ($new_anchor || !$active) {
            my ($ghost_index, $ghost_price) = _latest_extreme(
                $candles, $anchor_index + 1, $event_index, $ghost_type,
            );
            next unless defined $ghost_index;
            $active = {
                type => $ghost_type, index => $ghost_index,
                price => $ghost_price + 0,
            };
            push @events, _trace_event(
                \@events, $candles, $event_index, $active, 'appearance',
                $anchor_index, $os,
            );
            next;
        }

        my $price = $candles->[$event_index]{$ghost_type};
        my $moves_outward = $ghost_type eq 'high'
            ? $price > $active->{price}
            : $price < $active->{price};
        if ($moves_outward) {
            @{$active}{qw(index price)} = ($event_index, $price + 0);
            push @events, _trace_event(
                \@events, $candles, $event_index, $active, 'move',
                $anchor_index, $os,
            );
        }
        elsif ($price == $active->{price}) {
            $active->{index} = $event_index;
        }
    }

    my $current;
    if ($active) {
        $current = {
            %$active,
            anchor_index => $anchor_index,
            anchor_price => $anchor_price,
            anchor_type => $os == 1 ? 'high' : 'low',
            max_visible_index => $max_idx,
            replay_safe => 1,
        };
    }
    return (\@events, \@anchors, $current);
}

sub _trace_event {
    my ($events, $candles, $event_index, $active, $relocation,
        $anchor_index, $os) = @_;
    my $serial = scalar @$events;
    return {
        event_id => join('_', 'ghost_trace', $active->{type},
            $event_index, $active->{index}, $serial),
        kind => 'ghostTrace', source => 'Ghosts_in_swings.txt',
        event_index => $event_index,
        ghost_index => $active->{index},
        ghost_price => $active->{price} + 0,
        ghost_type => $active->{type},
        relocation => $relocation,
        anchor_index => $anchor_index,
        anchor_type => $os == 1 ? 'high' : 'low',
        event_timestamp => $candles->[$event_index]{time},
        label => '1', confirmed => 1, replay_safe => 1,
    };
}

sub _latest_extreme {
    my ($candles, $start, $end, $type) = @_;
    $start = 0 if $start < 0;
    return if $start > $end || $end > $#$candles;
    my ($best_index, $best_price);
    for my $index ($start .. $end) {
        my $price = $candles->[$index]{$type};
        next unless defined $price;
        if (!defined($best_price)
            || ($type eq 'high' ? $price >= $best_price : $price <= $best_price)) {
            ($best_index, $best_price) = ($index, $price);
        }
    }
    return ($best_index, $best_price);
}

sub _finite {
    my ($value) = @_;
    return defined($value) && !ref($value)
        && "$value" =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/
        && $value == $value && abs($value) <= 1e300;
}

sub snapshot_at {
    my ($self, $last_index) = @_;
    my $candles = $self->{_candles} // [];
    $last_index //= $#$candles;
    my $snapshot = ref($self)->new(
        length       => $self->{length},
        show_regular => $self->{show_regular},
        show_missed  => $self->{show_missed},
    );
    return $snapshot->compute(candles => $candles, max_visible_index => $last_index);
}

1;
