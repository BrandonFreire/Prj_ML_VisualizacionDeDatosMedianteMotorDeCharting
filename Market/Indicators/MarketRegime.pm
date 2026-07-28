package Market::Indicators::MarketRegime;

use strict;
use warnings;


sub new {
    my ($class, %args) = @_;
    return bless {
        near_internal => $args{near_internal} // 0.50,
        near_external => $args{near_external} // 0.75,
        _lq_ref       => $args{liquidity_indicator},
        _smc_ref      => $args{smc_indicator},
        _market       => undef,
        _states       => [],
    }, $class;
}

sub set_liquidity_indicator { $_[0]->{_lq_ref}  = $_[1]; return }
sub set_smc_indicator       { $_[0]->{_smc_ref} = $_[1]; return }
sub reset                   { $_[0]->{_states}  = [];    return }

sub compute_all {
    my ($self, $market) = @_;
    $self->reset();
    $self->{_market} = $market;

    my $candles = $market ? $market->get_active_candles() : [];
    my $lq      = $self->{_lq_ref};
    my $smc     = $self->{_smc_ref};
    $self->{_states} = $self->_compute_states(
        candles           => $candles,
        atr_series        => $lq  ? $lq->get_atr()         : [],
        liquidity_levels  => $lq  ? $lq->get_levels()      : [],
        bos_events        => $smc ? $smc->get_bos_events() : [],
        choch_events      => $smc ? $smc->get_choch_events(): [],
    );
    return $self->{_states};
}

sub compute_from_inputs {
    my ($self, %args) = @_;
    return $self->_compute_states(%args);
}

sub _compute_states {
    my ($self, %args) = @_;
    my $candles = $args{candles} // [];
    my $n       = scalar @$candles;
    return [] unless $n;

    my $max_idx = defined $args{max_visible_index}
        ? int($args{max_visible_index}) : $n - 1;
    $max_idx = $n - 1 if $max_idx > $n - 1;
    return [] if $max_idx < 0;

    my $atr_s  = $args{atr_series}       // [];
    my $levels = $args{liquidity_levels} // [];
    my @bos    = @{ $args{bos_events}    // [] };
    my @choch  = @{ $args{choch_events}  // [] };

    my %structure_at;
    for my $event (@bos) {
        next unless defined $event->{index};
        push @{ $structure_at{ $event->{index} } }, { %$event, type => 'BOS' };
    }
    for my $event (@choch) {
        next unless defined $event->{index};
        push @{ $structure_at{ $event->{index} } }, { %$event, type => 'CHOCH' };
    }

    my @vol_avg = _volume_average($candles, $max_idx);
    my ($previous_state, @states) = ('UNKNOWN');

    for my $i (0 .. $max_idx) {
        my $c   = $candles->[$i];
        my $atr = $atr_s->[$i] // 0;
        my ($near_internal, $near_external) = $self->_nearest_levels(
            $c->{close}, $atr, $levels, $i,
        );
        my @liquidity_events = grep {
            defined($_->{resolved_at}) && $_->{resolved_at} == $i
        } @$levels;
        my @structure_events = @{ $structure_at{$i} // [] };

        my ($state, $reason, $score) = $self->_base_state(
            $atr, $near_internal, $near_external, $levels, $i,
        );
        ($state, $reason, $score) = $self->_apply_transitions(
            $state, $reason, $score, \@liquidity_events,
            \@structure_events, $previous_state, $i,
        );
        $score += 0.05 if _high_volume($c, $vol_avg[$i]);
        $score  = 1 if $score > 1;
        $score  = 0 if $score < 0;

        my $nearest = $near_external // $near_internal;
        my $last_lq = @liquidity_events ? $liquidity_events[-1] : undef;
        my $last_st = @structure_events ? $structure_events[-1] : undef;
        push @states, {
            index                    => $i,
            time                     => $c->{time},
            previous_state           => $previous_state,
            state                    => $state,
            reason                   => $reason,
            confidence_score         => sprintf('%.2f', $score) + 0,
            atr                      => $atr + 0,
            nearest_liquidity_index  => $nearest ? $nearest->{index} : undef,
            nearest_liquidity_scope  => $near_external ? 'external'
                                      : $near_internal ? 'internal' : 'none',
            nearest_liquidity_type   => $nearest ? $nearest->{type} : 'none',
            last_liquidity_index     => $last_lq ? $last_lq->{index} : undef,
            last_liquidity_class     => $last_lq ? $last_lq->{classification} : undef,
            last_structure_index     => $last_st ? $last_st->{index} : undef,
            last_structure_type      => $last_st ? $last_st->{type} : undef,
            max_visible_index        => $max_idx,
            replay_safe              => 1,
        };
        $previous_state = $state;
    }
    return \@states;
}

sub _nearest_levels {
    my ($self, $price, $atr, $levels, $index) = @_;
    return (undef, undef) unless defined $price && $atr > 0;

    my ($best_internal, $best_external);
    my ($dist_internal, $dist_external) = (9e99, 9e99);
    for my $level (@$levels) {
        next unless _level_available_at($level, $index);
        next if defined($level->{resolved_at}) && $level->{resolved_at} <= $index;
        my $scope = _scope_at($level, $index);
        my $dist  = abs($price - ($level->{price} // next));
        my $limit = $atr * ($scope eq 'external'
            ? $self->{near_external} : $self->{near_internal});
        next if $dist > $limit;

        my $copy = { %$level, effective_scope => $scope, distance => $dist };
        if ($scope eq 'external') {
            ($best_external, $dist_external) = ($copy, $dist)
                if $dist < $dist_external;
        }
        else {
            ($best_internal, $dist_internal) = ($copy, $dist)
                if $dist < $dist_internal;
        }
    }
    return ($best_internal, $best_external);
}

sub _base_state {
    my ($self, $atr, $near_internal, $near_external, $levels, $index) = @_;
    return ('UNKNOWN', 'ATR aun no disponible', 0.30) unless $atr > 0;

    if ($near_external) {
        return ('LIQUIDEZ_EXTERNA',
            sprintf('Precio cerca de %s externa', $near_external->{type} // 'liquidez'),
            0.60);
    }
    if ($near_internal) {
        return ('LIQUIDEZ_INTERNA',
            sprintf('Precio cerca de %s interna', $near_internal->{type} // 'liquidez'),
            0.52);
    }
    my $known = scalar grep { _level_available_at($_, $index) } @$levels;
    return $known
        ? ('ZONA_INTERNA', 'Precio dentro del rango local', 0.45)
        : ('UNKNOWN', 'Sin pivotes de liquidez confirmados', 0.35);
}

sub _apply_transitions {
    my ($self, $state, $reason, $score, $lq_events, $structure_events,
        $previous_state, $index) = @_;

    my @external_lq = grep {
        _scope_at($_, $index) eq 'external'
            && _is_sweep_or_grab($_->{classification})
    } @$lq_events;
    my @internal_lq = grep {
        _scope_at($_, $index) eq 'internal'
            && _is_sweep_or_grab($_->{classification})
    } @$lq_events;
    my @external_structure = grep {
        _scope_at($_, $index) eq 'external'
    } @$structure_events;
    my ($external_bos) = grep { ($_->{type} // '') eq 'BOS' } @external_structure;
    my ($external_choch) = grep { ($_->{type} // '') eq 'CHOCH' } @external_structure;
    my ($external_run) = grep {
        _scope_at($_, $index) eq 'external'
            && ($_->{classification} // '') eq 'RUN'
    } @$lq_events;

    if (@external_lq && $external_choch) {
        return ('TRANSITION', 'Barrido externo y CHoCH externo confirmados', $score + 0.30);
    }
    if ($external_run && $external_bos) {
        my $trend = ($external_bos->{direction} // '') eq 'bull'
            ? 'TR_BULLISH' : 'TR_BEARISH';
        return ($trend, 'RUN externo y BOS externo confirmados', $score + 0.35);
    }
    if ($external_bos) {
        my $trend = ($external_bos->{direction} // '') eq 'bull'
            ? 'TR_BULLISH' : 'TR_BEARISH';
        return ($trend, 'BOS externo confirmado', $score + 0.25);
    }
    if ($external_choch) {
        return ('TRANSITION', 'CHoCH externo confirmado', $score + 0.20);
    }
    if (@internal_lq) {
        return ('ZM_MANIPULATION', 'Barrido interno sin confirmacion externa', $score + 0.10);
    }
    if ($previous_state eq 'TRANSITION'
        && ($state eq 'ZONA_INTERNA' || $state eq 'LIQUIDEZ_INTERNA')) {
        return ('ZM_MANIPULATION', 'Transicion sin confirmacion externa', $score - 0.05);
    }
    if (($previous_state eq 'TR_BULLISH' || $previous_state eq 'TR_BEARISH')
        && !@$lq_events && !@$structure_events) {
        return ($previous_state, "$reason (continuacion)", $score + 0.05);
    }
    return ($state, $reason, $score);
}

sub _level_available_at {
    my ($level, $index) = @_;
    return ($level->{confirmed_at} // $level->{index} // 0) <= $index;
}

sub _scope_at {
    my ($item, $index) = @_;
    return 'internal' unless ($item->{scope} // 'internal') eq 'external';
    my $confirmed = $item->{scope_confirmed_at}
        // $item->{confirmed_at} // $item->{index} // 0;
    return $confirmed <= $index ? 'external' : 'internal';
}

sub _is_sweep_or_grab {
    my ($kind) = @_;
    return ($kind // '') =~ /^(?:SWEEP|GRAB|BIG_GRAB)$/ ? 1 : 0;
}

sub _volume_average {
    my ($candles, $max_idx) = @_;
    my ($sum, @avg) = 0;
    my $window = 20;
    for my $i (0 .. $max_idx) {
        $sum += $candles->[$i]{volume} // 0;
        $sum -= $candles->[$i - $window]{volume} // 0 if $i >= $window;
        my $count = $i + 1 < $window ? $i + 1 : $window;
        $avg[$i] = $count ? $sum / $count : 0;
    }
    return @avg;
}

sub _high_volume {
    my ($candle, $average) = @_;
    return 0 unless defined $average && $average > 0;
    return (($candle->{volume} // 0) >= $average * 1.35) ? 1 : 0;
}

sub get_states { return $_[0]->{_states} }

sub snapshot_at {
    my ($self, $last_index) = @_;
    my $market = $self->{_market} or return [];
    my $candles = $market->get_active_candles();
    return [] unless @$candles;
    $last_index //= $#$candles;
    my $lq  = $self->{_lq_ref};
    my $smc = $self->{_smc_ref};
    return $self->_compute_states(
        candles           => $candles,
        atr_series        => $lq  ? $lq->get_atr()         : [],
        liquidity_levels  => $lq  ? $lq->get_levels()      : [],
        bos_events        => $smc ? $smc->get_bos_events() : [],
        choch_events      => $smc ? $smc->get_choch_events(): [],
        max_visible_index => $last_index,
    );
}

1;
