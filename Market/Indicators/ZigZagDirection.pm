package Market::Indicators::ZigZagDirection;

use strict;
use warnings;

# Two-level ZigZag direction engine.
# - external: long local pivots on the active chart timeframe
# - internal: pivots on synthetic resolution candles mapped back to chart indices

sub new {
    my ($class, %args) = @_;
    return bless {
        external_length      => $args{external_length}      // 150,
        internal_resolution  => $args{internal_resolution}  // 15,
        internal_period      => $args{internal_period}      // 2,
        _external_pivots     => [],
        _external_raw        => [],
        _external_segments   => [],
        _internal_pivots     => [],
        _internal_raw        => [],
        _internal_segments   => [],
        _internal_candles    => [],
        _candles             => undef,
    }, $class;
}

sub reset {
    my ($self) = @_;
    $self->{_external_pivots}   = [];
    $self->{_external_raw}      = [];
    $self->{_external_segments} = [];
    $self->{_internal_pivots}   = [];
    $self->{_internal_raw}      = [];
    $self->{_internal_segments} = [];
    $self->{_internal_candles}  = [];
    $self->{_candles}           = undef;
}

sub compute_all {
    my ($self, $market) = @_;
    $self->reset();

    my $arr = $market->get_active_candles();
    $self->{_candles} = $arr;
    return unless $arr && @$arr;

    my $external_depth = _adaptive_external_depth(
        scalar(@$arr),
        _positive_int( $self->{external_length}, 150 ),
    );
    my @external_raw = _confirmed_pivots_from_candles( $arr, $external_depth );
    $self->{_external_raw} = [ @external_raw ];
    my $external_pivots = _compress_to_zigzag(\@external_raw);
    $external_pivots = _annotate_hldv($external_pivots);
    $self->{_external_pivots} = $external_pivots;
    $self->{_external_segments} = _segments_from_pivots( $external_pivots, 'external' );

    my $resolution = _positive_int( $self->{internal_resolution}, 15 );
    my $period     = _positive_int( $self->{internal_period}, 2 );
    my $mtf = _aggregate_resolution_candles( $arr, $resolution );
    $self->{_internal_candles} = $mtf;

    my @internal_raw = _confirmed_pivots_from_resolution_candles( $mtf, $period );
    $self->{_internal_raw} = [ @internal_raw ];
    my $internal_pivots = _compress_to_zigzag(\@internal_raw);
    $self->{_internal_pivots} = $internal_pivots;
    $self->{_internal_segments} = _segments_from_pivots( $internal_pivots, 'internal' );
}

sub update_last {
    my ($self, $market) = @_;
    $self->compute_all($market);
}

sub get_values { return [] }

sub get_external_pivots   { return $_[0]->{_external_pivots}   }
sub get_external_segments { return $_[0]->{_external_segments} }
sub get_internal_pivots   { return $_[0]->{_internal_pivots}   }
sub get_internal_segments { return $_[0]->{_internal_segments} }
sub get_internal_candles  { return $_[0]->{_internal_candles}  }

sub get_external_pivots_until {
    my ($self, $current_bar) = @_;
    return _annotate_hldv(
        _pivots_until($self->{_external_raw}, $current_bar, $self->{_candles})
    );
}

sub get_external_segments_until {
    my ($self, $current_bar) = @_;
    return _segments_from_pivots( $self->get_external_pivots_until($current_bar), 'external' );
}

sub get_internal_pivots_until {
    my ($self, $current_bar) = @_;
    return _pivots_until($self->{_internal_raw}, $current_bar, $self->{_candles});
}

sub get_internal_segments_until {
    my ($self, $current_bar) = @_;
    return _segments_from_pivots( $self->get_internal_pivots_until($current_bar), 'internal' );
}

sub _positive_int {
    my ($value, $default) = @_;
    $value = defined $value ? int($value) : $default;
    return $value > 0 ? $value : $default;
}

sub _adaptive_external_depth {
    my ($n, $configured) = @_;
    $configured = _positive_int($configured, 150);

    my $cap = int($n / 8);
    $cap = 2 if $cap < 2;
    $cap = $configured if $cap > $configured;
    return $cap;
}

sub _confirmed_pivots_from_candles {
    my ($arr, $depth) = @_;
    my $n = scalar @$arr;
    return () if $n < 2 * $depth + 1;

    my @pivots;
    for my $i ( $depth .. $n - $depth - 1 ) {
        my $high = $arr->[$i]{high};
        my $low  = $arr->[$i]{low};
        next unless defined $high && defined $low;

        my ($is_high, $is_low) = (1, 1);
        for my $j (1 .. $depth) {
            my $lh = $arr->[$i - $j]{high};
            my $rh = $arr->[$i + $j]{high};
            my $ll = $arr->[$i - $j]{low};
            my $rl = $arr->[$i + $j]{low};

            $is_high = 0 if !defined $lh || !defined $rh || $high <= $lh || $high <= $rh;
            $is_low  = 0 if !defined $ll || !defined $rl || $low  >= $ll || $low  >= $rl;
            last unless $is_high || $is_low;
        }

        my $confirmed_at = $i + $depth;
        push @pivots, {
            id           => join('_', 'zz', 'external', 'high', $i, $confirmed_at),
            index        => $i,
            price        => $high,
            type         => 'high',
            confirmed_at => $confirmed_at,
        } if $is_high;
        push @pivots, {
            id           => join('_', 'zz', 'external', 'low', $i, $confirmed_at),
            index        => $i,
            price        => $low,
            type         => 'low',
            confirmed_at => $confirmed_at,
        } if $is_low;
    }
    return @pivots;
}

sub _aggregate_resolution_candles {
    my ($arr, $resolution_minutes) = @_;
    my $seconds = $resolution_minutes * 60;
    $seconds = 60 if $seconds < 60;

    my @out;
    my $current_bucket;

    for my $i (0 .. $#$arr) {
        my $c = $arr->[$i] // next;
        my $bucket = defined $c->{time}
            ? int( $c->{time} / $seconds ) * $seconds
            : int( $i / $resolution_minutes );

        if ( !@out || !defined $current_bucket || $bucket != $current_bucket ) {
            $current_bucket = $bucket;
            push @out, {
                bucket       => $bucket,
                source_start => $i,
                source_end   => $i,
                open         => $c->{open},
                high         => $c->{high},
                low          => $c->{low},
                close        => $c->{close},
                volume       => $c->{volume} // 0,
                high_index   => $i,
                low_index    => $i,
            };
            next;
        }

        my $bar = $out[-1];
        $bar->{source_end} = $i;
        $bar->{close}      = $c->{close};
        $bar->{volume}    += $c->{volume} // 0;
        if ( defined $c->{high} && (!defined $bar->{high} || $c->{high} > $bar->{high}) ) {
            $bar->{high}       = $c->{high};
            $bar->{high_index} = $i;
        }
        if ( defined $c->{low} && (!defined $bar->{low} || $c->{low} < $bar->{low}) ) {
            $bar->{low}       = $c->{low};
            $bar->{low_index} = $i;
        }
    }

    return \@out;
}

sub _confirmed_pivots_from_resolution_candles {
    my ($bars, $depth) = @_;
    my $n = scalar @$bars;
    return () if $n < 2 * $depth + 1;

    my @pivots;
    for my $i ( $depth .. $n - $depth - 1 ) {
        my $high = $bars->[$i]{high};
        my $low  = $bars->[$i]{low};
        next unless defined $high && defined $low;

        my ($is_high, $is_low) = (1, 1);
        for my $j (1 .. $depth) {
            my $lh = $bars->[$i - $j]{high};
            my $rh = $bars->[$i + $j]{high};
            my $ll = $bars->[$i - $j]{low};
            my $rl = $bars->[$i + $j]{low};

            $is_high = 0 if !defined $lh || !defined $rh || $high <= $lh || $high <= $rh;
            $is_low  = 0 if !defined $ll || !defined $rl || $low  >= $ll || $low  >= $rl;
            last unless $is_high || $is_low;
        }

        my $confirm_bar = $bars->[ $i + $depth ];
        my $confirmed_at = $confirm_bar->{source_end};
        push @pivots, {
            id           => join('_', 'zz', 'internal', 'high', $bars->[$i]{high_index}, $confirmed_at),
            index        => $bars->[$i]{high_index},
            price        => $high,
            type         => 'high',
            confirmed_at => $confirmed_at,
        } if $is_high;
        push @pivots, {
            id           => join('_', 'zz', 'internal', 'low', $bars->[$i]{low_index}, $confirmed_at),
            index        => $bars->[$i]{low_index},
            price        => $low,
            type         => 'low',
            confirmed_at => $confirmed_at,
        } if $is_low;
    }
    return @pivots;
}

sub _compress_to_zigzag {
    my ($raw) = @_;
    my @raw = sort {
        $a->{index} <=> $b->{index}
            || (($a->{type} // '') cmp ($b->{type} // ''))
            || $a->{price} <=> $b->{price}
    } grep {
        defined $_->{index} && defined $_->{price} && defined $_->{type}
    } @$raw;

    my @zz;
    for my $p (@raw) {
        my %point = %$p;
        if (!@zz) {
            push @zz, \%point;
            next;
        }

        my $last = $zz[-1];
        if ( $point{type} eq $last->{type} ) {
            my $replace = $point{type} eq 'high'
                ? $point{price} >= $last->{price}
                : $point{price} <= $last->{price};
            $zz[-1] = \%point if $replace;
            next;
        }

        if ( $point{index} == $last->{index} ) {
            if ( @zz > 1 ) {
                my $prev = $zz[-2];
                my $old_move = abs( $last->{price} - $prev->{price} );
                my $new_move = abs( $point{price} - $prev->{price} );
                $zz[-1] = \%point if $new_move > $old_move;
            }
            next;
        }

        push @zz, \%point;
    }

    return \@zz;
}

sub _annotate_hldv {
    my ($pivots) = @_;
    return [] unless $pivots && ref($pivots) eq 'ARRAY';
    my ($last_high, $last_low);
    my @out;
    for my $pivot (@$pivots) {
        my %copy = %$pivot;
        if (($copy{type} // '') eq 'high') {
            $copy{label} = defined($last_high) && $copy{price} > $last_high ? 'HH' : 'LH';
            $last_high = $copy{price};
        }
        elsif (($copy{type} // '') eq 'low') {
            $copy{label} = defined($last_low) && $copy{price} > $last_low ? 'HL' : 'LL';
            $last_low = $copy{price};
        }
        push @out, \%copy;
    }
    return \@out;
}

sub _pivots_until {
    my ($raw, $current_bar, $candles) = @_;
    return [] unless $raw && @$raw;
    return _compress_to_zigzag($raw) unless defined $current_bar;

    my @ready = grep {
        defined $_->{index}
            && defined $_->{confirmed_at}
            && $_->{index} <= $current_bar
            && $_->{confirmed_at} <= $current_bar
    } @$raw;
    my $pivots = _compress_to_zigzag(\@ready);
    return _append_developing_pivot($pivots, $candles, $current_bar);
}

sub _append_developing_pivot {
    my ($pivots, $candles, $current_bar) = @_;
    return $pivots unless $candles && @$candles && defined $current_bar;
    return $pivots unless $pivots && @$pivots;

    $current_bar = $#$candles if $current_bar > $#$candles;
    return $pivots if $current_bar < 0;

    my @zz = map { { %$_ } } @$pivots;
    return \@zz unless @zz;

    my $last = $zz[-1];
    return \@zz unless defined $last->{index} && defined $last->{type};
    return \@zz if $last->{index} >= $current_bar;

    my $from = $last->{index} + 1;
    my $to   = $current_bar;
    return \@zz if $from > $to;

    # Un pivote confirmado es inmutable. El extremo en desarrollo siempre es
    # el extremo opuesto siguiente; puede desplazarse mientras sea provisional.
    my $wanted = $last->{type} eq 'high' ? 'low' : 'high';
    my $developing = _range_extreme($candles, $from, $to, $wanted);
    if ($developing && $developing->{index} > $last->{index}) {
        push @zz, {
            %$developing,
            id           => join('_', 'zz', 'provisional', $wanted, $last->{id} // $last->{index}),
            type         => $wanted,
            confirmed_at => $current_bar,
            provisional  => 1,
        };
    }
    return \@zz;
}

sub _range_extreme {
    my ($candles, $from, $to, $field) = @_;
    return unless $candles && @$candles;
    $from = 0 if $from < 0;
    $to = $#$candles if $to > $#$candles;
    return if $from > $to;

    my $best;
    for my $i ($from .. $to) {
        my $c = $candles->[$i] // next;
        my $price = $c->{$field};
        next unless defined $price;
        if (
            !$best
            || ($field eq 'high' && $price >= $best->{price})
            || ($field eq 'low'  && $price <= $best->{price})
        ) {
            $best = {
                index => $i,
                price => $price,
            };
        }
    }
    return $best;
}

sub _segments_from_pivots {
    my ($pivots, $scope) = @_;
    my @segments;
    return \@segments unless $pivots && @$pivots >= 2;

    for my $i (1 .. $#$pivots) {
        my $from = $pivots->[$i - 1];
        my $to   = $pivots->[$i];
        next if $from->{index} == $to->{index};
        next if !defined $from->{price} || !defined $to->{price};

        push @segments, {
            id           => join('_', 'zzseg', $scope, $from->{id} // $from->{index}, $to->{id} // $to->{index}),
            from_index   => $from->{index},
            from_price   => $from->{price},
            from_type    => $from->{type},
            to_index     => $to->{index},
            to_price     => $to->{price},
            to_type      => $to->{type},
            direction    => $to->{price} >= $from->{price} ? 'bull' : 'bear',
            confirmed_at => $to->{confirmed_at},
            scope        => $scope,
        };
    }
    return \@segments;
}

1;
