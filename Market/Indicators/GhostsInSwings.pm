package Market::Indicators::GhostsInSwings;

use strict;
use warnings;

# Motor causal del fantasma flotante de Ghosts_in_swings.  Un pivote regular
# se confirma length velas después; desde ese momento el fantasma busca el
# extremo opuesto al último pivote.  Un rastro se emite sólo si ese extremo se
# desplaza hacia fuera.  Esto evita que una vela sin cambio de extremo cuente
# repetidamente como etiqueta "1".

sub new {
    my ($class, %args) = @_;
    return bless {
        length          => _length($args{length} // $args{pivot_length} // 50),
        _candles        => [],
        _regular_pivots => [],
        _relocations     => [],
        _trails          => [],
        _active_by_index => [],
        _max_index       => -1,
    }, $class;
}

sub reset {
    my ($self) = @_;
    $self->{_candles}        = [];
    $self->{_regular_pivots} = [];
    $self->{_relocations}    = [];
    $self->{_trails}         = [];
    $self->{_active_by_index}= [];
    $self->{_max_index}      = -1;
    return;
}

sub compute_all {
    my ($self, $market) = @_;
    my $candles = $market ? $market->get_active_candles() : [];
    return $self->compute(candles => $candles);
}

sub update_last { return $_[0]->compute_all($_[1]); }

sub compute {
    my ($class_or_self, %args) = @_;
    my $self = ref($class_or_self) ? $class_or_self : $class_or_self->new(%args);
    my $candles = $args{candles} // [];
    die 'GhostsInSwings::compute: candles debe ser un arrayref'
        unless ref($candles) eq 'ARRAY';

    $self->reset();
    $self->{length} = _length($args{length} // $args{pivot_length})
        if exists($args{length}) || exists($args{pivot_length});
    _validate_candles($candles);

    my @series = map { { %$_ } } @$candles;
    $self->{_candles} = \@series;
    my $last = $#series;
    $self->{_max_index} = $last;
    return $self->_result if $last < 0;

    my $length = $self->{length};
    my ($last_type, $base_index, $base_price, $active);
    my ($candidate_index, $candidate_price, $candidate_type);

    for my $cursor (0 .. $last) {
        my $center = $cursor - $length;
        my ($pivot_high, $pivot_low) = (0, 0);
        if ($center >= $length) {
            $pivot_high = _is_pivot(\@series, $center, $length, 'high');
            $pivot_low  = _is_pivot(\@series, $center, $length, 'low');

            # Una vela exterior no puede producir dos anclas opuestas.  Se
            # conserva la alternancia, como hace el estado os del Pine.
            if ($pivot_high && $pivot_low) {
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
        }

        my $new_anchor = 0;
        if ($pivot_high || $pivot_low) {
            my $type = $pivot_high ? 'high' : 'low';
            my $price = $series[$center]{$type};
            my $pivot = {
                id           => join('_', 'ghost_regular', $type, $center, $cursor),
                kind         => 'regular_pivot', type => $type,
                index        => $center, time => $series[$center]{time},
                price        => $price + 0,
                confirmed_at => $cursor, confirmed_time => $series[$cursor]{time},
                replay_safe  => 1,
            };
            push @{ $self->{_regular_pivots} }, $pivot;
            ($last_type, $base_index, $base_price) = ($type, $center, $price + 0);
            $active = undef;
            ($candidate_index, $candidate_price, $candidate_type) = (undef, undef, undef);
            $new_anchor = 1;
        }

        if (defined($last_type) && defined($base_index) && $cursor > $base_index) {
            my $ghost_type = $last_type eq 'high' ? 'low' : 'high';
            # El Pine reconstruye el extremo desde el pivote cuando cambia el
            # ancla. Después basta actualizar el máximo/mínimo acumulado con
            # la vela nueva: O(N * length) en vez de O(N²).
            if ($new_anchor) {
                ($candidate_index, $candidate_price) = _extreme_since(
                    \@series, $base_index + 1, $cursor, $ghost_type,
                );
                $candidate_type = $ghost_type;
            }
            else {
                my $price = $series[$cursor]{$ghost_type};
                if (!defined($candidate_price)
                    || ($ghost_type eq 'high' ? $price > $candidate_price : $price < $candidate_price)) {
                    ($candidate_index, $candidate_price, $candidate_type) =
                        ($cursor, $price, $ghost_type);
                }
            }
            my ($ghost_index, $ghost_price) = ($candidate_index, $candidate_price);
            if (defined $ghost_index) {
                my $changed = !$active
                    || $active->{ghost_index} != $ghost_index
                    || $active->{price} != $ghost_price;
                if ($changed) {
                    my $is_move = $active ? 1 : 0;
                    my $event = {
                        id => join('_', 'ghost_relocated', $ghost_type, $cursor,
                            $ghost_index, scalar @{ $self->{_relocations} }),
                        kind => 'ghost_relocated', event_type => 'ghost_relocated',
                        occurrence_index => $cursor, occurrence_time => $series[$cursor]{time},
                        ghost_index => $ghost_index, ghost_time => $series[$ghost_index]{time},
                        price => $ghost_price + 0, type => $ghost_type,
                        direction => $ghost_type eq 'low' ? 1 : -1,
                        anchor_index => $base_index, anchor_price => $base_price + 0,
                        relocation => $is_move ? 'move' : 'appearance',
                        replay_safe => 1,
                    };
                    push @{ $self->{_relocations} }, $event;
                    if ($is_move) {
                        my %trail = %$event;
                        $trail{id} = join('_', 'trail', $ghost_type, $cursor,
                            $ghost_index, scalar @{ $self->{_trails} });
                        $trail{kind} = 'trail';
                        $trail{event_type} = 'trail';
                        $trail{label} = '1';
                        push @{ $self->{_trails} }, \%trail;
                    }
                    $active = {
                        %$event,
                        status => 'active',
                    };
                }
            }
        }
        $self->{_active_by_index}[$cursor] = $active ? { %$active } : undef;
    }
    return $self->_result;
}

sub _extreme_since {
    my ($candles, $from, $to, $type) = @_;
    return unless $from <= $to;
    my ($best_i, $best_price);
    for my $i ($from .. $to) {
        my $price = $candles->[$i]{$type};
        next unless defined $price;
        if (!defined($best_price)
            || ($type eq 'high' ? $price > $best_price : $price < $best_price)) {
            ($best_i, $best_price) = ($i, $price);
        }
    }
    return ($best_i, $best_price);
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

sub _result {
    my ($self) = @_;
    return {
        pivot_length => $self->{length}, max_visible_index => $self->{_max_index},
        regular_pivots => [ map { { %$_ } } @{ $self->{_regular_pivots} } ],
        relocations => [ map { { %$_ } } @{ $self->{_relocations} } ],
        trails => [ map { { %$_ } } @{ $self->{_trails} } ],
        active_ghost => $self->get_active_ghost_at($self->{_max_index}),
        replay_safe => 1,
    };
}

sub snapshot_at {
    my ($self, $cursor) = @_;
    $cursor = $self->{_max_index} unless defined $cursor;
    die 'GhostsInSwings::snapshot_at: cursor debe ser un entero'
        unless defined($cursor) && $cursor =~ /^-?\d+$/;
    $cursor = int($cursor);
    $cursor = $self->{_max_index} if $cursor > $self->{_max_index};
    return {
        pivot_length => $self->{length}, max_visible_index => $cursor,
        regular_pivots => [ map { { %$_ } } grep { $_->{confirmed_at} <= $cursor } @{ $self->{_regular_pivots} } ],
        relocations => [ map { { %$_ } } grep { $_->{occurrence_index} <= $cursor } @{ $self->{_relocations} } ],
        trails => [ map { { %$_ } } grep { $_->{occurrence_index} <= $cursor } @{ $self->{_trails} } ],
        active_ghost => $self->get_active_ghost_at($cursor), replay_safe => 1,
    };
}

sub get_regular_pivots { return $_[0]->{_regular_pivots} }
sub get_relocations { return $_[0]->{_relocations} }
sub get_trails { return $_[0]->{_trails} }
sub get_max_index { return $_[0]->{_max_index} }
sub get_result { return $_[0]->_result }

sub get_active_ghost_at {
    my ($self, $cursor) = @_;
    return undef if ($self->{_max_index} // -1) < 0;
    $cursor = $self->{_max_index} unless defined $cursor;
    return undef unless $cursor =~ /^-?\d+$/;
    $cursor = int($cursor);
    return undef if $cursor < 0;
    $cursor = $self->{_max_index} if $cursor > $self->{_max_index};
    my $active = $self->{_active_by_index}[$cursor];
    return $active ? { %$active } : undef;
}

sub _validate_candles {
    my ($candles) = @_;
    for my $i (0 .. $#$candles) {
        die "GhostsInSwings: vela $i invalida" unless ref($candles->[$i]) eq 'HASH';
        for my $key (qw(high low)) {
            die "GhostsInSwings: vela $i sin $key numerico finito"
                unless _finite($candles->[$i]{$key});
        }
        die "GhostsInSwings: vela $i con high menor que low"
            if $candles->[$i]{high} < $candles->[$i]{low};
    }
}

sub _finite {
    my ($value) = @_;
    return defined($value) && !ref($value)
        && "$value" =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/
        && $value == $value && abs($value) <= 1e300;
}

sub _length {
    my ($length) = @_;
    $length = 50 unless defined($length) && $length =~ /^\d+$/;
    $length = int($length);
    $length = 1 if $length < 1;
    $length = 500 if $length > 500;
    return $length;
}

1;
