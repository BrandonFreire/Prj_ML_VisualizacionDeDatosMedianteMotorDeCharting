package Market::Indicators::Liquidity;

use strict;
use warnings;


sub new {
    my ($class, %args) = @_;
    my $eq_tolerance_atr = $args{eq_tolerance_atr} // 0.05;
    die 'Liquidity::new: eq_tolerance_atr debe estar entre 0 y 1'
        unless defined($eq_tolerance_atr) && !ref($eq_tolerance_atr)
            && $eq_tolerance_atr =~ /^(?:\d+(?:\.\d*)?|\.\d+)$/
            && $eq_tolerance_atr > 0 && $eq_tolerance_atr <= 1;
    return bless {
        depth      => $args{depth}      // 3,
        external_depth => $args{external_depth},
        n_accept   => $args{n_accept}   // 3,
        atr_period => $args{atr_period} // 14,
        eq_tolerance_atr => $eq_tolerance_atr + 0,
        _levels    => [],
        _atr       => [],
        _candles   => undef,
        _market    => undef,
    }, $class;
}

sub reset { my ($self) = @_; $self->{_levels} = []; $self->{_atr} = []; }

sub get_candles { return $_[0]->{_candles} // [] }

sub compute_all {
    my ($self, $market) = @_;
    $self->reset();
    $self->{_market} = $market;

    my $arr = $market->get_active_candles();
    $self->{_candles} = $arr;
    my $n   = scalar @$arr;
    my $k   = $self->{depth};
    return if $n < 2 * $k + 2;
    my $external_k = _adaptive_external_depth(
        $n,
        $self->{external_depth} // ($k * 3),
        $k,
    );

    my @atr = _simple_atr($arr, $self->{atr_period});
    $self->{_atr} = \@atr;

    my (@sh, @sl);
    for my $i ( $k .. $n - $k - 1 ) {
        my ($is_sh, $is_sl) = (1, 1);
        for my $j (1 .. $k) {
            $is_sh = 0 if $arr->[$i]{high} <= $arr->[$i-$j]{high}
                       || $arr->[$i]{high} <= $arr->[$i+$j]{high};
            $is_sl = 0 if $arr->[$i]{low}  >= $arr->[$i-$j]{low}
                       || $arr->[$i]{low}  >= $arr->[$i+$j]{low};
        }
        if ($is_sh) {
            push @sh, _make_level($i, $arr->[$i]{high}, 'BSL', 'sh', $i + $k);
        }
        if ($is_sl) {
            push @sl, _make_level($i, $arr->[$i]{low},  'SSL', 'sl', $i + $k);
        }
    }

    my (%external_sh, %external_sl);
    if ( $n >= 2 * $external_k + 2 ) {
        for my $i ( $external_k .. $n - $external_k - 1 ) {
            my ($is_sh, $is_sl) = (1, 1);
            for my $j (1 .. $external_k) {
                $is_sh = 0 if $arr->[$i]{high} <= $arr->[$i-$j]{high}
                           || $arr->[$i]{high} <= $arr->[$i+$j]{high};
                $is_sl = 0 if $arr->[$i]{low}  >= $arr->[$i-$j]{low}
                           || $arr->[$i]{low}  >= $arr->[$i+$j]{low};
            }
            $external_sh{$i} = $i + $external_k if $is_sh;
            $external_sl{$i} = $i + $external_k if $is_sl;
        }
    }
    for my $lvl (@sh) {
        if ( defined $external_sh{ $lvl->{index} } ) {
            $lvl->{scope} = 'external';
            $lvl->{scope_confirmed_at} = $external_sh{ $lvl->{index} };
        } else {
            $lvl->{scope} = 'internal';
            $lvl->{scope_confirmed_at} = $lvl->{confirmed_at};
        }
    }
    for my $lvl (@sl) {
        if ( defined $external_sl{ $lvl->{index} } ) {
            $lvl->{scope} = 'external';
            $lvl->{scope_confirmed_at} = $external_sl{ $lvl->{index} };
        } else {
            $lvl->{scope} = 'internal';
            $lvl->{scope_confirmed_at} = $lvl->{confirmed_at};
        }
    }

    _mark_equal_levels(\@sh, \@atr, $arr, 'high', $self->{eq_tolerance_atr});
    _mark_equal_levels(\@sl, \@atr, $arr, 'low',  $self->{eq_tolerance_atr});

    my @all = sort { $a->{index} <=> $b->{index} } (@sh, @sl);

    for my $lvl (@all) {
        _run_state_machine($lvl, $arr, $n, $self->{n_accept});
    }

    $self->_attach_volume_weights(\@all, $arr);

    $self->{_levels} = \@all;
}

sub _attach_volume_weights {
    my ($self, $levels, $arr) = @_;
    my $market = $self->{_market};
    return unless $market;

    my $vi = $market->can('get_volume_index') ? $market->get_volume_index() : {};

    for my $lvl (@$levels) {
        my $ref_idx = $lvl->{swept_at} // $lvl->{index};
        next unless defined $ref_idx && defined $arr->[$ref_idx];

        my $candle_time = $arr->[$ref_idx]{time};
        my $vol_data    = $vi->{$candle_time};

        if ($vol_data) {
            $lvl->{volume_weight} = {
                v1m  => $vol_data->{v1m}  // 0,
                v5m  => $vol_data->{v5m}  // 0,
                v15m => $vol_data->{v15m} // 0,
            };
            $lvl->{volume_weight_source} = 'multi_timeframe_index';
        } else {
            my $v = $arr->[$ref_idx]{volume} // 0;
            $lvl->{volume_weight} = { v1m => $v, v5m => 0, v15m => 0 };
            $lvl->{volume_weight_source} = 'native_fallback';
        }
        my $w = $lvl->{volume_weight};
        $lvl->{volume_score} = ($w->{v1m} // 0)
                             + ($w->{v5m} // 0)
                             + ($w->{v15m} // 0);
    }
}

sub _run_state_machine {
    my ($lvl, $arr, $n, $n_accept) = @_;
    my $det_i = $lvl->{index};
    my $confirmed_at = $lvl->{confirmed_at} // $det_i;
    my $price = $lvl->{price};
    my $side  = $lvl->{side};

    my $swept_i = undef;
    for my $i ($confirmed_at + 1 .. $n - 1) {
        if ($side eq 'sh' && $arr->[$i]{high} > $price) { $swept_i = $i; last }
        if ($side eq 'sl' && $arr->[$i]{low}  < $price) { $swept_i = $i; last }
    }

    unless (defined $swept_i) {
        return;
    }

    $lvl->{state}    = 'SWEPT';
    $lvl->{swept_at} = $swept_i;
    $lvl->{state_path} = ['DETECTED', 'SWEPT'];

    my $consec_out = 0;
    my $max_look   = _min($swept_i + 30, $n - 1);

    for my $i ($swept_i .. $max_look) {
        my $close_out = ($side eq 'sh')
            ? $arr->[$i]{close} > $price
            : $arr->[$i]{close} < $price;

        if ($close_out) {
            $consec_out++;
            if ($consec_out >= $n_accept) {
                $lvl->{state}          = 'ACCEPTANCE';
                $lvl->{resolved_at}    = $i;
                $lvl->{classification} = 'RUN';
                $lvl->{state}          = 'RESOLVED';
                $lvl->{state_path}     = [
                    'DETECTED', 'SWEPT', 'ACCEPTANCE', 'RESOLVED',
                ];
                return;
            }
        } else {
            my $bars_out = $i - $swept_i;
            my $class = $bars_out == 0 ? 'SWEEP'
                      : $bars_out <= 3
                          ? (($lvl->{scope} // 'internal') eq 'external' ? 'BIG_GRAB' : 'GRAB')
                          : 'SWEEP';
            $lvl->{state}          = 'RECLAIMED';
            $lvl->{resolved_at}    = $i;
            $lvl->{classification} = $class;
            $lvl->{bars_out}       = $bars_out;
            $lvl->{max_consec_out} = $consec_out;
            $lvl->{state}          = 'RESOLVED';
            $lvl->{state_path}     = [
                'DETECTED', 'SWEPT', 'RECLAIMED', 'RESOLVED',
            ];
            return;
        }
    }

    $lvl->{state}          = 'SWEPT';
    $lvl->{resolved_at}    = undef;
    $lvl->{classification} = undef;
    $lvl->{bars_out}       = $max_look - $swept_i;
    $lvl->{max_consec_out} = $consec_out;
}

sub _make_level {
    my ($index, $price, $type, $side, $confirmed_at) = @_;
    return {
        index          => $index,
        price          => $price,
        type           => $type,
        side           => $side,
        confirmed_at   => $confirmed_at // $index,
        scope          => 'internal',
        scope_confirmed_at => $confirmed_at // $index,
        is_eqh         => 0,
        is_eql         => 0,
        eq_confirmed_at => undef,
        eq_pair        => undef,
        eq_pair_price  => undef,
        eq_price       => undef,
        eq_tolerance   => undef,
        eq_deviation_atr => undef,
        state          => 'DETECTED',
        state_path     => ['DETECTED'],
        swept_at       => undef,
        resolved_at    => undef,
        classification => undef,
        volume_weight  => undef,
        volume_weight_source => undef,
        volume_score   => 0,
    };
}

sub _mark_equal_levels {
    my ($levels, $atr, $candles, $kind, $tolerance_factor) = @_;
    return unless $levels && @$levels > 1;
    $tolerance_factor //= 0.05;
    my $flag = $kind eq 'high' ? 'is_eqh' : 'is_eql';
    my $prefix = $kind eq 'high' ? 'EQH' : 'EQL';

    for my $b (1 .. $#$levels) {
        my $new = $levels->[$b];
        my $new_idx = $new->{index};
        next unless defined $new_idx;

        for (my $a = $b - 1; $a >= 0; $a--) {
            my $prior = $levels->[$a];
            my $prior_idx = $prior->{index};
            next unless defined $prior_idx && $prior_idx < $new_idx;
            last if ($new_idx - $prior_idx) > 100;

            my @atr_values = grep { defined($_) && $_ > 0 }
                ($atr->[$prior_idx], $atr->[$new_idx]);
            next unless @atr_values;
            my $atr_mean = 0;
            $atr_mean += $_ for @atr_values;
            $atr_mean /= @atr_values;
            my $tolerance = $atr_mean * $tolerance_factor;
            my $difference = abs($prior->{price} - $new->{price});
            next if $tolerance <= 0 || $difference > $tolerance;
            next if _equal_level_consumed_before(
                $prior, $candles, $new_idx, $kind, $tolerance,
            );

            my $eq_confirmed_at = _max(
                $prior->{confirmed_at} // $prior_idx,
                $new->{confirmed_at} // $new_idx,
            );
            my $eq_price = ($prior->{price} + $new->{price}) / 2;
            my $cluster_id = join('_', lc($prefix), $prior_idx, $new_idx);

            $prior->{$flag} = 1;
            $new->{$flag} = 1;
            $prior->{eq_confirmed_at} = $eq_confirmed_at
                if !defined($prior->{eq_confirmed_at})
                    || $eq_confirmed_at < $prior->{eq_confirmed_at};
            push @{ $prior->{eq_cluster_ids} //= [] }, $cluster_id;

            $new->{eq_confirmed_at} = $eq_confirmed_at;
            $new->{eq_pair} = $prior_idx;
            $new->{eq_pair_price} = $prior->{price} + 0;
            $new->{eq_pair_confirmed_at} = $prior->{confirmed_at} // $prior_idx;
            $new->{eq_price} = $eq_price + 0;
            $new->{eq_tolerance} = $tolerance + 0;
            $new->{eq_deviation_atr} = $atr_mean > 0 ? $difference / $atr_mean : 0;
            $new->{eq_cluster_id} = $cluster_id;
            last;
        }
    }
}

sub _equal_level_consumed_before {
    my ($level, $candles, $new_index, $kind, $tolerance) = @_;
    my $from = ($level->{confirmed_at} // $level->{index}) + 1;
    my $to = $new_index - 1;
    return 0 if $from > $to;

    for my $i ($from .. $to) {
        my $candle = $candles->[$i] // next;
        if ($kind eq 'high') {
            return 1 if defined($candle->{high})
                && $candle->{high} > $level->{price} + $tolerance;
        }
        else {
            return 1 if defined($candle->{low})
                && $candle->{low} < $level->{price} - $tolerance;
        }
    }
    return 0;
}

sub _simple_atr {
    my ($arr, $period) = @_;
    my $n  = scalar @$arr;
    my @tr = ($arr->[0]{high} - $arr->[0]{low});
    for my $i (1 .. $n-1) {
        my $hl  = $arr->[$i]{high} - $arr->[$i]{low};
        my $hpc = abs($arr->[$i]{high} - $arr->[$i-1]{close});
        my $lpc = abs($arr->[$i]{low}  - $arr->[$i-1]{close});
        push @tr, ($hl > $hpc ? ($hl > $lpc ? $hl : $lpc) : ($hpc > $lpc ? $hpc : $lpc));
    }
    my @atr = (undef) x $n;
    if ($n > $period) {
        my $sum = 0;
        $sum += $tr[$_] for (1 .. $period);
        $atr[$period] = $sum / $period;
        for my $i ($period+1 .. $n-1) {
            $atr[$i] = ($atr[$i-1] * ($period-1) + $tr[$i]) / $period;
        }
    }
    return @atr;
}

sub _min { $_[0] < $_[1] ? $_[0] : $_[1] }
sub _max { $_[0] > $_[1] ? $_[0] : $_[1] }

sub _adaptive_external_depth {
    my ($n, $configured, $internal_k) = @_;
    $configured = defined $configured ? int($configured) : ($internal_k * 3);
    $configured = $internal_k + 2 if $configured <= $internal_k;

    my $cap = int($n / 8);
    $cap = $internal_k + 2 if $cap < $internal_k + 2;
    $cap = $configured if $cap > $configured;
    return $cap;
}

sub get_levels     { return $_[0]->{_levels} }
sub get_atr        { return $_[0]->{_atr}    }

sub get_levels_at {
    my ($self, $last_index) = @_;
    my $market = $self->{_market} or return [];

    $last_index //= $market->last_index();
    my $prefix = $market->clone_upto($last_index);
    my $snapshot = ref($self)->new(
        depth          => $self->{depth},
        external_depth => $self->{external_depth},
        n_accept       => $self->{n_accept},
        atr_period     => $self->{atr_period},
        eq_tolerance_atr => $self->{eq_tolerance_atr},
    );
    $snapshot->compute_all($prefix);
    return $snapshot->get_levels();
}

sub get_active_at {
    my ($self, $last_index) = @_;
    return [ grep {
        ($_->{state} // '') eq 'DETECTED' || ($_->{state} // '') eq 'SWEPT'
    } @{ $self->get_levels_at($last_index) } ];
}

sub get_resolved_at {
    my ($self, $last_index) = @_;
    return [ grep { defined $_->{classification} } @{ $self->get_levels_at($last_index) } ];
}

sub get_bsl_levels {
    return [ grep { $_->{side} eq 'sh' && $_->{state} eq 'DETECTED' }
             @{ $_[0]->{_levels} } ];
}
sub get_ssl_levels {
    return [ grep { $_->{side} eq 'sl' && $_->{state} eq 'DETECTED' }
             @{ $_[0]->{_levels} } ];
}

sub get_active {
    return [ grep { $_->{state} eq 'DETECTED' || $_->{state} eq 'SWEPT' }
             @{ $_[0]->{_levels} } ];
}
sub get_resolved {
    return [ grep { defined $_->{classification} } @{ $_[0]->{_levels} } ];
}
sub get_by_class {
    my ($self, $class) = @_;
    return [ grep { ($_->{classification}//'') eq $class } @{ $self->{_levels} } ];
}
sub get_eqh {
    return [ grep { $_->{is_eqh} } @{ $_[0]->{_levels} } ];
}
sub get_eql {
    return [ grep { $_->{is_eql} } @{ $_[0]->{_levels} } ];
}
sub get_eqh_pairs {
    return [ grep { $_->{is_eqh} && defined $_->{eq_pair} } @{ $_[0]->{_levels} } ];
}
sub get_eql_pairs {
    return [ grep { $_->{is_eql} && defined $_->{eq_pair} } @{ $_[0]->{_levels} } ];
}

sub get_weighted_levels {
    my ($self, $min_percentile) = @_;
    $min_percentile //= 0.5;
    my $levels = $self->{_levels} // [];

    my @vols = sort { $a <=> $b }
               grep { $_ > 0 }
               map  { $_->{volume_score} // 0 } @$levels;
    return $levels unless @vols;

    my $idx = int($min_percentile * $#vols + 0.5);
    $idx = 0      if $idx < 0;
    $idx = $#vols if $idx > $#vols;
    my $threshold = $vols[$idx];

    return [ grep {
        ($_->{volume_score} // 0) >= $threshold
    } @$levels ];
}

1;
