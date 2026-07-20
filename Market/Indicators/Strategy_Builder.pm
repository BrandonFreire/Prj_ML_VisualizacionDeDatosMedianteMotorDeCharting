package Market::Indicators::Strategy_Builder;

use strict;
use warnings;

# DIY Custom Strategy Builder — Motor de cálculo (Sección 6)
#
# Procesa en tiempo real las reglas de entrada/salida combinando
# indicadores técnicos y volumen.  Estricta separación de Overlays.
#
# Componentes:
#   SuperTrend   — bandas ATR con flip dinámico
#   HalfTrend    — dirección de tendencia con filtros de reversión
#   Range Filter — suavizado dinámico del precio
#   Supply/Demand Zones — OBs validados por volumen

sub new {
    my ($class, %args) = @_;
    return bless {
        # SuperTrend params
        st_multiplier  => $args{st_multiplier}  // 3.0,
        st_period      => $args{st_period}      // 10,

        # HalfTrend params
        ht_amplitude   => $args{ht_amplitude}   // 2,
        ht_channel_dev => $args{ht_channel_dev} // 2,

        # Range Filter params
        rf_period      => $args{rf_period}      // 100,
        rf_multiplier  => $args{rf_multiplier}  // 3.0,

        # Supply/Demand volume threshold (percentil)
        sd_vol_pct     => $args{sd_vol_pct}     // 0.70,

        # Motor de señales: el indicador principal debe cambiar de dirección;
        # las confirmaciones pueden aprobar en la misma vela o antes de expirar.
        signal_main_indicator     => $args{signal_main_indicator} // 'supertrend',
        signal_confirmations      => $args{signal_confirmations}  // [],
        signal_confirmation_mode  => uc($args{signal_confirmation_mode} // 'AND'),
        signal_expiry_bars        => $args{signal_expiry_bars} // 3,
        signal_alternating_only   => exists $args{signal_alternating_only}
            ? ($args{signal_alternating_only} ? 1 : 0) : 1,

        # Results
        _supertrend    => [],
        _halftrend     => [],
        _range_filter  => [],
        _supply_zones  => [],
        _demand_zones  => [],
        _signals       => [],
        _candles       => undef,
        _smc_ref       => undef,   # ref a SMC_Structures para OBs
    }, $class;
}

sub set_smc_indicator {
    my ($self, $smc) = @_;
    $self->{_smc_ref} = $smc;
}

sub reset {
    my ($self) = @_;
    $self->{$_} = [] for qw(_supertrend _halftrend _range_filter _supply_zones _demand_zones _signals);
    $self->{_candles} = undef;
}

sub compute_all {
    my ($self, $market) = @_;
    $self->reset();

    my $arr = $market->_active_array();
    $self->{_candles} = $arr;
    my $n = scalar @$arr;
    return if $n < 2;

    # Pre-compute ATR for SuperTrend
    my @atr = _simple_atr($arr, $self->{st_period});

    # 1. SuperTrend
    $self->{_supertrend} = $self->_compute_supertrend($arr, \@atr);

    # 2. HalfTrend
    $self->{_halftrend} = $self->_compute_halftrend($arr, \@atr);

    # 3. Range Filter
    $self->{_range_filter} = $self->_compute_range_filter($arr);

    # 4. Señales configurables sobre series ya calculadas.
    $self->compute_signals($arr);

    # 5 & 6. Supply / Demand Zones (basados en OBs de SMC)
    $self->_compute_supply_demand($arr, $market);
}

# ================================================================
# Señales LONG/SHORT configurables
# ================================================================
sub set_signal_configuration {
    my ($self, %args) = @_;
    for my $key (qw(signal_main_indicator signal_confirmations signal_expiry_bars signal_alternating_only)) {
        $self->{$key} = $args{$key} if exists $args{$key};
    }
    if (exists $args{signal_confirmation_mode}) {
        my $mode = uc($args{signal_confirmation_mode} // 'AND');
        $self->{signal_confirmation_mode} = $mode eq 'OR' ? 'OR' : 'AND';
    }
    return;
}

sub get_signal_configuration {
    my ($self) = @_;
    return {
        main_indicator   => $self->{signal_main_indicator},
        confirmations    => [ @{ $self->{signal_confirmations} // [] } ],
        confirmation_mode => $self->{signal_confirmation_mode} // 'AND',
        expiry_bars      => $self->{signal_expiry_bars} // 3,
        alternating_only => $self->{signal_alternating_only} ? 1 : 0,
    };
}

sub compute_signals {
    my ($self, $candles) = @_;
    $candles //= $self->{_candles} // [];
    my $n = scalar @$candles;
    my @signals;
    return $self->{_signals} = \@signals unless $n;

    my $main = $self->{signal_main_indicator} // 'supertrend';
    my @confirmations = grep { $_ ne $main } @{ $self->{signal_confirmations} // [] };
    my $mode = ($self->{signal_confirmation_mode} // 'AND') eq 'OR' ? 'OR' : 'AND';
    my $expiry = int($self->{signal_expiry_bars} // 3);
    $expiry = 1 if $expiry < 1;
    my $alternate_only = $self->{signal_alternating_only} ? 1 : 0;
    my ($pending, $last_side);

    for my $i (0 .. $n - 1) {
        my $direction = $self->_signal_direction_at($main, $i);
        my $previous  = $i > 0 ? $self->_signal_direction_at($main, $i - 1) : undef;
        my %row = (
            index => $i,
            time  => $candles->[$i]{time},
            main_indicator => $main,
            main_direction => $direction,
            long_signal => 0,
            short_signal => 0,
            replay_safe => 1,
        );

        if (defined $direction && $direction != 0
            && defined $previous && $previous != 0 && $direction != $previous) {
            $pending = {
                direction => $direction,
                trigger_index => $i,
                expires_at_index => $i + $expiry,
            };
        }

        if ($pending && $i <= $pending->{expires_at_index}) {
            my (@passed, @failed);
            for my $name (@confirmations) {
                my $confirmation_direction = $self->_signal_direction_at($name, $i);
                if (defined $confirmation_direction && $confirmation_direction == $pending->{direction}) {
                    push @passed, $name;
                } else {
                    push @failed, $name;
                }
            }
            my $confirmed = !@confirmations
                || ($mode eq 'AND' ? !@failed : @passed);

            if ($confirmed) {
                my $side = $pending->{direction} > 0 ? 'LONG' : 'SHORT';
                my $blocked = $alternate_only && defined($last_side) && $last_side eq $side;
                unless ($blocked) {
                    $row{side}                 = $side;
                    $row{long_signal}          = $side eq 'LONG' ? 1 : 0;
                    $row{short_signal}         = $side eq 'SHORT' ? 1 : 0;
                    $row{trigger_index}        = $pending->{trigger_index};
                    $row{expires_at_index}     = $pending->{expires_at_index};
                    $row{confirmations_passed} = \@passed;
                    $row{confirmations_failed} = \@failed;
                    $row{confidence} = @confirmations
                        ? scalar(@passed) / scalar(@confirmations) : 1;
                    $last_side = $side;
                }
                $pending = undef;
            }
        }
        elsif ($pending && $i > $pending->{expires_at_index}) {
            $pending = undef;
        }

        push @signals, \%row;
    }
    $self->{_signals} = \@signals;
    return \@signals;
}

sub _signal_direction_at {
    my ($self, $name, $index) = @_;
    if ($name eq 'supertrend') {
        return $self->{_supertrend}[$index]{direction}
            if defined $self->{_supertrend}[$index]{direction};
    }
    elsif ($name eq 'halftrend') {
        return ($self->{_halftrend}[$index]{trend} // 1) == 0 ? 1 : -1
            if defined $self->{_halftrend}[$index];
    }
    elsif ($name eq 'range_filter') {
        return $self->{_range_filter}[$index]{direction}
            if defined $self->{_range_filter}[$index]{direction};
    }
    return undef;
}

# ================================================================
# SuperTrend — Cálculo por vela cerrada basado en multiplicador ATR
# ================================================================
sub _compute_supertrend {
    my ($self, $arr, $atr) = @_;
    my $n    = scalar @$arr;
    my $mult = $self->{st_multiplier};
    my @st;

    my ($prev_upper, $prev_lower, $prev_dir) = (0, 0, 1);

    for my $i (0 .. $n - 1) {
        my $atr_val = $atr->[$i] // 0;
        my $hl2     = ($arr->[$i]{high} + $arr->[$i]{low}) / 2;

        # Bandas básicas
        my $basic_upper = $hl2 + $mult * $atr_val;
        my $basic_lower = $hl2 - $mult * $atr_val;

        # Bandas finales: mantener si el precio anterior no las rompió
        my $final_upper = $basic_upper;
        my $final_lower = $basic_lower;

        if ($i > 0) {
            my $prev_close = $arr->[$i-1]{close};
            $final_upper = $basic_upper < $prev_upper || $prev_close > $prev_upper
                ? $basic_upper : $prev_upper;
            $final_lower = $basic_lower > $prev_lower || $prev_close < $prev_lower
                ? $basic_lower : $prev_lower;
        }

        # Dirección: flip cuando el cierre cruza la banda
        my $dir = $prev_dir;
        my $close = $arr->[$i]{close};
        if ($i > 0) {
            if ($prev_dir == -1 && $close > $prev_upper) {
                $dir = 1;
            } elsif ($prev_dir == 1 && $close < $prev_lower) {
                $dir = -1;
            }
        }

        my $value = $dir == 1 ? $final_lower : $final_upper;

        push @st, {
            value     => $value,
            direction => $dir,     # 1 = bull, -1 = bear
            upper     => $final_upper,
            lower     => $final_lower,
        };

        $prev_upper = $final_upper;
        $prev_lower = $final_lower;
        $prev_dir   = $dir;
    }

    return \@st;
}

# ================================================================
# HalfTrend — Determinación de dirección y filtros de reversión
# ================================================================
sub _compute_halftrend {
    my ($self, $arr, $atr) = @_;
    my $n         = scalar @$arr;
    my $amplitude = $self->{ht_amplitude};
    my $dev       = $self->{ht_channel_dev};
    my @ht;

    my $trend        = 0;     # 0=up, 1=down
    my $next_trend   = 0;
    my $max_low_price  = $arr->[0]{low};
    my $min_high_price = $arr->[0]{high};
    my $up   = 0;
    my $down = 0;
    my $atr_high = 0;
    my $atr_low  = 0;

    for my $i (0 .. $n - 1) {
        my $c = $arr->[$i];
        my $atr_val = ($atr->[$i] // 0) / 2;

        # Determinar máximo de lows y mínimo de highs en ventana amplitude
        my $lo_start = $i - $amplitude; $lo_start = 0 if $lo_start < 0;
        my $hi_start = $i - $amplitude; $hi_start = 0 if $hi_start < 0;

        my $highest_low  = $arr->[$lo_start]{low};
        my $lowest_high  = $arr->[$hi_start]{high};
        for my $j ($lo_start .. $i) {
            $highest_low = $arr->[$j]{low}  if $arr->[$j]{low}  > $highest_low;
            $lowest_high = $arr->[$j]{high} if $arr->[$j]{high} < $lowest_high;
        }

        my $high_price = $c->{high};
        my $low_price  = $c->{low};

        $max_low_price  = $low_price  if $low_price  > $max_low_price;
        $max_low_price  = $highest_low;
        $min_high_price = $high_price if $high_price < $min_high_price;
        $min_high_price = $lowest_high;

        if ($next_trend == 1) {
            $max_low_price = $low_price if $low_price < $max_low_price;
            $max_low_price = $highest_low;
        }
        if ($next_trend == 0) {
            $min_high_price = $high_price if $high_price > $min_high_price;
            $min_high_price = $lowest_high;
        }

        # Flip conditions
        if ($trend == 0 && $c->{close} < $up - $atr_val) {
            $trend = 1;
            $next_trend = 1;
            $min_high_price = $high_price;
        }
        if ($trend == 1 && $c->{close} > $down + $atr_val) {
            $trend = 0;
            $next_trend = 0;
            $max_low_price = $low_price;
        }

        if ($trend == 0) {
            $up = $max_low_price > $up ? $max_low_price : $up;
            $atr_high = $up + $dev * ($atr->[$i] // 0);
            $atr_low  = $up - $dev * ($atr->[$i] // 0);
        } else {
            $down = $min_high_price < $down || $down == 0 ? $min_high_price : $down;
            $atr_high = $down + $dev * ($atr->[$i] // 0);
            $atr_low  = $down - $dev * ($atr->[$i] // 0);
        }

        push @ht, {
            trend     => $trend,      # 0=up, 1=down
            value     => $trend == 0 ? $up : $down,
            atr_high  => $atr_high,
            atr_low   => $atr_low,
            flipped   => ($i > 0 && @ht && $ht[-1]{trend} != $trend) ? 1 : 0,
        };
    }

    return \@ht;
}

# ================================================================
# Range Filter — Suavizado dinámico del precio
# ================================================================
sub _compute_range_filter {
    my ($self, $arr) = @_;
    my $n      = scalar @$arr;
    my $period = $self->{rf_period};
    my $mult   = $self->{rf_multiplier};
    my @rf;

    # Compute smoothed range using EMA of absolute bar range
    my @abs_range;
    for my $i (0 .. $n - 1) {
        push @abs_range, abs($arr->[$i]{high} - $arr->[$i]{low});
    }

    # EMA of range
    my @ema_range = (0) x $n;
    my $k = 2.0 / ($period + 1);
    $ema_range[0] = $abs_range[0];
    for my $i (1 .. $n - 1) {
        $ema_range[$i] = $abs_range[$i] * $k + $ema_range[$i-1] * (1 - $k);
    }

    my $filter = $arr->[0]{close};
    my $prev_filter = $filter;
    my $direction   = 0;  # 1=up, -1=down

    for my $i (0 .. $n - 1) {
        my $smooth_range = $ema_range[$i] * $mult;
        my $src = $arr->[$i]{close};

        my $new_filter;
        if ($src > $prev_filter) {
            $new_filter = ($src - $smooth_range) > $prev_filter
                ? ($src - $smooth_range) : $prev_filter;
        } elsif ($src < $prev_filter) {
            $new_filter = ($src + $smooth_range) < $prev_filter
                ? ($src + $smooth_range) : $prev_filter;
        } else {
            $new_filter = $prev_filter;
        }

        my $upward   = $new_filter > $prev_filter ? 1 : 0;
        my $downward = $new_filter < $prev_filter ? 1 : 0;
        $direction = $upward ? 1 : $downward ? -1 : $direction;

        push @rf, {
            filter_value => $new_filter,
            direction    => $direction,
            upward       => $upward,
            downward     => $downward,
            hi_band      => $new_filter + $smooth_range,
            lo_band      => $new_filter - $smooth_range,
        };

        $prev_filter = $new_filter;
    }

    return \@rf;
}

# ================================================================
# Supply / Demand Zones — OBs validados por volumen
# ================================================================
sub _compute_supply_demand {
    my ($self, $arr, $market) = @_;
    my $n   = scalar @$arr;
    my $smc = $self->{_smc_ref};
    return unless $smc && $smc->can('get_ob_zones');

    my $obs = $smc->get_ob_zones() // [];

    # Calcular percentil de volumen para umbral
    my @vols = sort { $a <=> $b }
               grep { defined $_ && $_ > 0 }
               map  { $arr->[$_]{volume} }
               grep { $_ >= 0 && $_ < $n }
               map  { $_->{index} // -1 }
               @$obs;

    my $pct = $self->{sd_vol_pct};
    my $threshold = 0;
    if (@vols) {
        my $idx = int($pct * $#vols + 0.5);
        $idx = 0      if $idx < 0;
        $idx = $#vols if $idx > $#vols;
        $threshold = $vols[$idx];
    }

    my (@supply, @demand);
    for my $ob (@$obs) {
        my $idx = $ob->{index};
        next unless defined $idx && $idx >= 0 && $idx < $n;
        my $vol = $arr->[$idx]{volume} // 0;
        next if $vol < $threshold;   # filtrar por volumen

        my $zone = {
            index        => $idx,
            top          => $ob->{top},
            bottom       => $ob->{bottom},
            direction    => $ob->{direction},
            volume       => $vol,
            volume_pct   => (@vols ? $vol / ($vols[-1] || 1) : 0),
            scope        => $ob->{scope}         // 'internal',
            confirmed_at => $ob->{confirmed_at}  // $idx,
            triggered_by => $ob->{triggered_by},
        };

        if (($ob->{direction} // '') eq 'bear') {
            push @supply, $zone;
        } else {
            push @demand, $zone;
        }
    }

    $self->{_supply_zones} = \@supply;
    $self->{_demand_zones} = \@demand;
}

# ================================================================
# ATR helper (Wilder's method, standalone for Strategy Builder)
# ================================================================
sub _simple_atr {
    my ($arr, $period) = @_;
    my $n  = scalar @$arr;
    my @tr = (0);
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
        # backfill warmup
        for my $i (0 .. $period - 1) {
            $atr[$i] = $atr[$period] if !defined $atr[$i] && defined $atr[$period];
        }
    }
    return @atr;
}

# ================================================================
# Accessors
# ================================================================
sub get_supertrend   { return $_[0]->{_supertrend}   }
sub get_halftrend    { return $_[0]->{_halftrend}     }
sub get_range_filter { return $_[0]->{_range_filter}  }
sub get_supply_zones { return $_[0]->{_supply_zones}  }
sub get_demand_zones { return $_[0]->{_demand_zones}  }
sub get_signals      { return $_[0]->{_signals}       }

1;
