package Market::Backtest;

use strict;
use warnings;


sub new {
    my ($class, %args) = @_;
    return bless {
        initial_capital  => $args{initial_capital}  // 10_000,
        risk_per_trade   => $args{risk_per_trade}   // 0.01,
        max_leverage     => $args{max_leverage}     // 1,
        stop_atr_multiple=> $args{stop_atr_multiple}// 1.5,
        reward_risk      => $args{reward_risk}      // 2,
        commission_bps   => $args{commission_bps}   // 0,
        slippage_bps     => $args{slippage_bps}     // 0,
        intrabar_priority=> $args{intrabar_priority}// 'stop_first',
    }, $class;
}

sub run {
    my ($self, %args) = @_;
    my $candles = $args{candles} // [];
    my $signals = $args{signals} // [];
    die 'Market::Backtest->run: candles debe ser un arrayref'
        unless ref($candles) eq 'ARRAY';
    die 'Market::Backtest->run: signals debe ser un arrayref'
        unless ref($signals) eq 'ARRAY';

    my $cfg = {
        %$self,
        map { $_ => $args{$_} } grep {
            exists $args{$_}
        } qw(initial_capital risk_per_trade max_leverage stop_atr_multiple
             reward_risk commission_bps slippage_bps intrabar_priority),
    };
    _validate_config($cfg);

    my $n = scalar @$candles;
    my $equity = $cfg->{initial_capital} + 0;
    my @trades;
    my @skipped;
    my @equity_curve;
    return _summary($cfg, $equity, \@trades, \@skipped, \@equity_curve)
        unless $n;

    my %entries_at;
    for my $signal (@$signals) {
        my $side = _signal_side($signal);
        next unless $side;
        my $signal_index = $signal->{index};
        unless (defined $signal_index && $signal_index =~ /^\d+$/) {
            push @skipped, { signal => $signal, reason => 'missing_signal_index' };
            next;
        }
        my $entry_index = $signal_index + 1;
        if ($entry_index >= $n) {
            push @skipped, {
                signal => $signal, side => $side, reason => 'no_next_open',
                entry_index => $entry_index,
            };
            next;
        }
        push @{ $entries_at{$entry_index} }, { %$signal, side => $side };
    }

    my $atr_series = $args{atr_series} // [];
    die 'Market::Backtest->run: atr_series debe ser un arrayref'
        unless ref($atr_series) eq 'ARRAY';
    my $regime_series = $args{regime_series} // [];
    die 'Market::Backtest->run: regime_series debe ser un arrayref'
        unless ref($regime_series) eq 'ARRAY';
    my %regime_at_signal;
    for my $regime (@$regime_series) {
        next unless ref($regime) eq 'HASH' && defined($regime->{index});
        $regime_at_signal{ $regime->{index} } = {
            state      => $regime->{state} // 'UNKNOWN',
            confidence => $regime->{confidence},
            trained_through => $regime->{trained_through},
        };
    }
    my $position;

    for my $i (0 .. $n - 1) {
        my $candle = $candles->[$i] // {};
        _validate_candle($candle, $i);
        my $had_position = $position ? 1 : 0;

        if ($position) {
            my ($exit_price, $exit_reason) = _bar_exit($position, $candle, $cfg);
            if (defined $exit_price) {
                $equity = _close_position(
                    position => $position, raw_exit => $exit_price,
                    exit_index => $i, exit_time => $candle->{time},
                    exit_reason => $exit_reason, equity => $equity,
                    cfg => $cfg, trades => \@trades,
                );
                $position = undef;
            }
        }

        if (!$position && !$had_position && $entries_at{$i}) {
            my $signal = shift @{ $entries_at{$i} };
            for my $ignored (@{ $entries_at{$i} }) {
                push @skipped, {
                    signal => $ignored, side => $ignored->{side},
                    entry_index => $i, reason => 'concurrent_signal',
                };
            }
            $position = _open_position(
                signal => $signal, candle => $candle, entry_index => $i,
                atr => $atr_series->[ $signal->{index} ], equity => $equity,
                regime => $regime_at_signal{ $signal->{index} },
                cfg => $cfg, skipped => \@skipped,
            );
            $equity -= $position->{entry_commission} if $position;

            if ($position) {
                my ($exit_price, $exit_reason) = _bar_exit($position, $candle, $cfg);
                if (defined $exit_price) {
                    $equity = _close_position(
                        position => $position, raw_exit => $exit_price,
                        exit_index => $i, exit_time => $candle->{time},
                        exit_reason => $exit_reason, equity => $equity,
                        cfg => $cfg, trades => \@trades,
                    );
                    $position = undef;
                }
            }
        }
        elsif ($had_position && $entries_at{$i}) {
            push @skipped, map {
                { signal => $_, side => $_->{side}, entry_index => $i,
                  reason => 'position_open_at_entry' }
            } @{ $entries_at{$i} };
        }

        if ($position && $i == $n - 1) {
            $equity = _close_position(
                position => $position, raw_exit => $candle->{close},
                exit_index => $i, exit_time => $candle->{time},
                exit_reason => 'end_of_data', equity => $equity,
                cfg => $cfg, trades => \@trades,
            );
            $position = undef;
        }

        my $marked_equity = $equity;
        if ($position) {
            $marked_equity += _unrealized_pnl($position, $candle->{close});
        }
        push @equity_curve, {
            index => $i, time => $candle->{time}, equity => $marked_equity + 0,
            replay_safe => 1,
        };
    }

    return _summary($cfg, $equity, \@trades, \@skipped, \@equity_curve);
}

sub backtest { return $_[0]->run(@_[1 .. $#_]) }

sub _open_position {
    my (%args) = @_;
    my ($signal, $candle, $cfg, $skipped) = @args{qw(signal candle cfg skipped)};
    my $side = $signal->{side};
    my $raw_entry = $candle->{open};
    my $entry = _apply_slippage($raw_entry, $side, 'entry', $cfg->{slippage_bps});

    my ($stop, $target) = _levels_for_signal($signal, $entry, $args{atr}, $cfg);
    unless (defined $stop && defined $target) {
        push @$skipped, {
            signal => $signal, side => $side, entry_index => $args{entry_index},
            reason => 'missing_or_invalid_risk_levels',
        };
        return;
    }
    my $risk_per_unit = abs($entry - $stop);
    unless ($risk_per_unit > 0 && $args{equity} > 0) {
        push @$skipped, {
            signal => $signal, side => $side, entry_index => $args{entry_index},
            reason => 'non_positive_position_risk',
        };
        return;
    }
    my $risk_capital = $args{equity} * $cfg->{risk_per_trade};
    my $units_by_risk = $risk_capital / $risk_per_unit;
    my $units_by_exposure = ($args{equity} * $cfg->{max_leverage}) / $entry;
    my $units = $units_by_risk < $units_by_exposure ? $units_by_risk : $units_by_exposure;
    unless ($units > 0) {
        push @$skipped, {
            signal => $signal, side => $side, entry_index => $args{entry_index},
            reason => 'zero_position_size',
        };
        return;
    }

    my $entry_commission = _commission($entry, $units, $cfg->{commission_bps});
    my $position = {
        side             => $side,
        signal_index     => $signal->{index},
        signal_time      => $signal->{time},
        entry_index      => $args{entry_index},
        entry_time       => $candle->{time},
        raw_entry_price  => $raw_entry + 0,
        entry_price      => $entry + 0,
        stop_price       => $stop + 0,
        target_price     => $target + 0,
        units            => $units + 0,
        risk_amount      => ($units * $risk_per_unit) + 0,
        entry_commission => $entry_commission + 0,
    };
    if (my $regime = $args{regime}) {
        $position->{regime_state} = $regime->{state};
        $position->{regime_confidence} = $regime->{confidence}
            if defined $regime->{confidence};
        $position->{regime_trained_through} = $regime->{trained_through}
            if defined $regime->{trained_through};
    }
    return $position;
}

sub _levels_for_signal {
    my ($signal, $entry, $atr, $cfg) = @_;
    my $side = $signal->{side};
    my $distance = defined($atr) && $atr > 0
        ? $atr * $cfg->{stop_atr_multiple} : undef;
    my $stop = defined $signal->{stop_price}
        ? $signal->{stop_price}
        : defined($distance) ? ($side eq 'LONG' ? $entry - $distance : $entry + $distance) : undef;
    my $target = defined $signal->{take_profit_price}
        ? $signal->{take_profit_price}
        : defined($stop) ? ($side eq 'LONG'
            ? $entry + ($entry - $stop) * $cfg->{reward_risk}
            : $entry - ($stop - $entry) * $cfg->{reward_risk}) : undef;
    return (undef, undef) unless defined $stop && defined $target;
    return (undef, undef) if $side eq 'LONG'  && !($stop < $entry && $target > $entry);
    return (undef, undef) if $side eq 'SHORT' && !($stop > $entry && $target < $entry);
    return ($stop + 0, $target + 0);
}

sub _bar_exit {
    my ($position, $candle, $cfg) = @_;
    my ($stop_hit, $target_hit);
    if ($position->{side} eq 'LONG') {
        $stop_hit   = $candle->{low}  <= $position->{stop_price};
        $target_hit = $candle->{high} >= $position->{target_price};
    }
    else {
        $stop_hit   = $candle->{high} >= $position->{stop_price};
        $target_hit = $candle->{low}  <= $position->{target_price};
    }
    return unless $stop_hit || $target_hit;

    my $reason = $stop_hit && $target_hit
        ? ($cfg->{intrabar_priority} eq 'target_first' ? 'target' : 'stop')
        : $stop_hit ? 'stop' : 'target';
    my $raw;
    if ($reason eq 'stop') {
        $raw = _gap_aware_price($position->{side}, 'stop', $candle->{open}, $position->{stop_price});
    }
    else {
        $raw = _gap_aware_price($position->{side}, 'target', $candle->{open}, $position->{target_price});
    }
    return ($raw, $reason);
}

sub _gap_aware_price {
    my ($side, $kind, $open, $level) = @_;
    return $level unless defined $open;
    return $side eq 'LONG'
        ? ($kind eq 'stop'   ? ($open < $level ? $open : $level)
                           : ($open > $level ? $open : $level))
        : ($kind eq 'stop'   ? ($open > $level ? $open : $level)
                           : ($open < $level ? $open : $level));
}

sub _close_position {
    my (%args) = @_;
    my ($position, $cfg, $trades) = @args{qw(position cfg trades)};
    my $exit = _apply_slippage(
        $args{raw_exit}, $position->{side}, 'exit', $cfg->{slippage_bps},
    );
    my $gross = _pnl($position, $exit);
    my $exit_commission = _commission($exit, $position->{units}, $cfg->{commission_bps});
    my $net = $gross - $position->{entry_commission} - $exit_commission;
    my $equity_after = $args{equity} + $gross - $exit_commission;

    push @$trades, {
        %$position,
        raw_exit_price  => $args{raw_exit} + 0,
        exit_price      => $exit + 0,
        exit_index      => $args{exit_index},
        exit_time       => $args{exit_time},
        exit_reason     => $args{exit_reason},
        exit_commission => $exit_commission + 0,
        gross_pnl       => $gross + 0,
        net_pnl         => $net + 0,
        return_pct      => $position->{entry_price}
            ? ($net / ($position->{entry_price} * $position->{units}) * 100) + 0 : 0,
        r_multiple      => $position->{risk_amount}
            ? ($net / $position->{risk_amount}) + 0 : 0,
        equity_after    => $equity_after + 0,
        replay_safe     => 1,
    };
    return $equity_after;
}

sub _summary {
    my ($cfg, $equity, $trades, $skipped, $curve) = @_;
    my ($wins, $gross_profit, $gross_loss) = (0, 0, 0);
    my %by_regime;
    for my $trade (@$trades) {
        $wins++ if $trade->{net_pnl} > 0;
        $gross_profit += $trade->{net_pnl} if $trade->{net_pnl} > 0;
        $gross_loss   += -$trade->{net_pnl} if $trade->{net_pnl} < 0;
        my $state = $trade->{regime_state} // 'UNKNOWN';
        my $bucket = $by_regime{$state} //= {
            trades => 0, wins => 0, losses => 0, net_pnl => 0,
            gross_profit => 0, gross_loss => 0,
        };
        $bucket->{trades}++;
        $bucket->{wins}++ if $trade->{net_pnl} > 0;
        $bucket->{losses}++ unless $trade->{net_pnl} > 0;
        $bucket->{net_pnl} += $trade->{net_pnl};
        $bucket->{gross_profit} += $trade->{net_pnl} if $trade->{net_pnl} > 0;
        $bucket->{gross_loss}   += -$trade->{net_pnl} if $trade->{net_pnl} < 0;
    }
    for my $bucket (values %by_regime) {
        $bucket->{win_rate} = $bucket->{trades} ? $bucket->{wins} / $bucket->{trades} : 0;
        $bucket->{profit_factor} = $bucket->{gross_loss} > 0
            ? $bucket->{gross_profit} / $bucket->{gross_loss}
            : $bucket->{gross_profit} > 0 ? undef : 0;
    }
    my ($peak, $max_drawdown) = ($cfg->{initial_capital}, 0);
    for my $point (@$curve) {
        $peak = $point->{equity} if $point->{equity} > $peak;
        my $dd = $peak ? ($peak - $point->{equity}) / $peak : 0;
        $max_drawdown = $dd if $dd > $max_drawdown;
    }
    return {
        assumptions => {
            entry_timing     => 'next_bar_open',
            intrabar_priority=> $cfg->{intrabar_priority},
            single_position  => 1,
            financing        => 'not_modeled',
        },
        initial_capital => $cfg->{initial_capital} + 0,
        final_equity    => $equity + 0,
        net_pnl         => ($equity - $cfg->{initial_capital}) + 0,
        return_pct      => $cfg->{initial_capital}
            ? (($equity / $cfg->{initial_capital} - 1) * 100) + 0 : 0,
        total_trades    => scalar @$trades,
        wins            => $wins,
        losses          => scalar(@$trades) - $wins,
        win_rate        => @$trades ? ($wins / @$trades) + 0 : 0,
        profit_factor   => $gross_loss > 0 ? ($gross_profit / $gross_loss) + 0
                         : $gross_profit > 0 ? undef : 0,
        max_drawdown    => $max_drawdown + 0,
        trades          => $trades,
        by_regime       => \%by_regime,
        skipped_signals => $skipped,
        equity_curve    => $curve,
        replay_safe     => 1,
    };
}

sub _pnl {
    my ($position, $exit) = @_;
    return ($exit - $position->{entry_price}) * $position->{units}
        if $position->{side} eq 'LONG';
    return ($position->{entry_price} - $exit) * $position->{units};
}

sub _unrealized_pnl { return _pnl($_[0], $_[1]) }

sub _commission {
    my ($price, $units, $bps) = @_;
    return $price * $units * $bps / 10_000;
}

sub _apply_slippage {
    my ($price, $side, $action, $bps) = @_;
    my $adverse = $side eq 'LONG'
        ? ($action eq 'entry' ? 1 : -1)
        : ($action eq 'entry' ? -1 : 1);
    return $price * (1 + $adverse * $bps / 10_000);
}

sub _signal_side {
    my ($signal) = @_;
    return unless ref($signal) eq 'HASH';
    my $side = uc($signal->{side} // '');
    return $side if $side eq 'LONG' || $side eq 'SHORT';
    return 'LONG'  if $signal->{long_signal};
    return 'SHORT' if $signal->{short_signal};
    return;
}

sub _validate_config {
    my ($cfg) = @_;
    die 'initial_capital debe ser > 0' unless $cfg->{initial_capital} > 0;
    die 'risk_per_trade debe estar en (0, 1]' unless $cfg->{risk_per_trade} > 0 && $cfg->{risk_per_trade} <= 1;
    die 'max_leverage debe ser > 0' unless $cfg->{max_leverage} > 0;
    die 'stop_atr_multiple debe ser > 0' unless $cfg->{stop_atr_multiple} > 0;
    die 'reward_risk debe ser > 0' unless $cfg->{reward_risk} > 0;
    die 'commission_bps no puede ser negativo' unless $cfg->{commission_bps} >= 0;
    die 'slippage_bps no puede ser negativo' unless $cfg->{slippage_bps} >= 0;
    $cfg->{intrabar_priority} = 'stop_first'
        unless ($cfg->{intrabar_priority} // '') eq 'target_first';
}

sub _validate_candle {
    my ($candle, $index) = @_;
    for my $field (qw(open high low close)) {
        die "vela $index sin $field" unless defined $candle->{$field};
    }
    die "vela $index con high < low" if $candle->{high} < $candle->{low};
}

1;
