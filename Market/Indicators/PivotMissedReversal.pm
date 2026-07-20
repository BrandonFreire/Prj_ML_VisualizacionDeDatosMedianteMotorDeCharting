package Market::Indicators::PivotMissedReversal;

use strict;
use warnings;

# Detector secuencial de pivotes regulares y de extremos de reversión que el
# zigzag convencional omitió. Un pivote en i existe solo al cerrar i+length;
# los "missed" se crean al confirmarse el siguiente pivote, nunca antes.

sub new {
    my ($class, %args) = @_;
    return bless {
        length       => _length($args{length} // $args{pivot_length} // 20),
        show_regular => exists $args{show_regular} ? ($args{show_regular} ? 1 : 0) : 1,
        show_missed  => exists $args{show_missed}  ? ($args{show_missed}  ? 1 : 0) : 1,
        _candles     => undef,
        _regular     => [],
        _missed      => [],
        _levels      => [],
        _ambiguous   => [],
    }, $class;
}

sub reset {
    my ($self) = @_;
    $self->{_regular} = [];
    $self->{_missed}  = [];
    $self->{_levels}  = [];
    $self->{_ambiguous} = [];
    $self->{_candles} = undef;
    return;
}

sub compute_all {
    my ($self, $market) = @_;
    my $candles = $market ? $market->_active_array() : [];
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

    my $max_idx = defined($args{max_visible_index})
        ? int($args{max_visible_index}) : $#$candles;
    $max_idx = $#$candles if $max_idx > $#$candles;
    return $self->_result(-1) if $max_idx < 0;
    my @series = map { { %{ $candles->[$_] } } } 0 .. $max_idx;
    _validate_candles(\@series);
    $self->{_candles} = \@series;

    my $length = $self->{length};
    my ($tracked_max, $tracked_min, $tracked_max_i, $tracked_min_i);
    my ($follow_max, $follow_min, $follow_max_i, $follow_min_i);
    my ($last_type, $last_index, $last_price);

    # n es la vela de confirmación; center es el posible pivot situado
    # exactamente length velas atrás.
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
        # Una vela exterior puede ser a la vez máximo y mínimo local. Emitir
        # ambos pivotes crearía un tramo de longitud cero; elegir siempre LOW
        # (la regla anterior) sesgaba la serie. Se conserva la alternancia
        # frente al último pivote confirmado y, si aún no hay contexto, se
        # deja la vela como ambigua sin inventar dirección.
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
            $self->_add_regular('low', $center, $low, $n) if $self->{show_regular};
            ($last_type, $last_index, $last_price) = ('low', $center, $low);
            ($tracked_max, $tracked_min, $tracked_max_i, $tracked_min_i) = ($low, $low, $center, $center);
            ($follow_max, $follow_min, $follow_max_i, $follow_min_i) = ($low, $low, $center, $center);
        }
    }
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
        label        => $type eq 'high' ? 'HIGH' : 'LOW',
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
        reason       => $reason, label => 'MISSED', replay_safe => 1,
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
        die "PivotMissedReversal: vela $i sin high" unless defined $candles->[$i]{high};
        die "PivotMissedReversal: vela $i sin low"  unless defined $candles->[$i]{low};
    }
}

sub _length {
    my ($length) = @_;
    $length = 20 unless defined($length) && $length =~ /^\d+$/;
    $length = int($length);
    $length = 1 if $length < 1;
    $length = 500 if $length > 500;
    return $length;
}

sub get_regular_pivots  { return $_[0]->{_regular} }
sub get_missed_pivots   { return $_[0]->{_missed}  }
sub get_reversal_levels { return $_[0]->{_levels}  }

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
