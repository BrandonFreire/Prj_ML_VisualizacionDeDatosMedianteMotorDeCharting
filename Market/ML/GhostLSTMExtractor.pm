package Market::ML::GhostLSTMExtractor;

use strict;
use warnings;
use POSIX qw(strftime);
use Market::Indicators::PivotMissedReversal;

# Exportador causal para la Fase 1 de LSTM.  No conoce Tk ni muta el cursor
# del ChartEngine; trabaja sobre el mismo arreglo histórico que usa Replay.
#
# El callback level_snapshot debe devolver, para cada categoria, una lista de
# niveles que YA existian en el cursor solicitado.  Formato:
# {
#   replay_safe => 1,
#   order_block => [ { level => 1.0820, range_low => 1.0816,
#                       range_high => 1.0824 } ],
#   fvg => [...], fibonacci => [...], anchored_vwap => [...],
#   volume_profile => [ { level => $poc, range_low => $val,
#                         range_high => $vah } ],
#   htf_sr => [...], bos_choch => [...], eqh_eql => [...],
#   sweep_grab_run => [...], supply_demand => [...],
#   channels_trendlines => [...],
# }
#
# Es valido que una categoria no tenga nivel; se exporta distancia 0 y su
# mascara *_available = 0. Esto conserva un CSV estrictamente numerico para
# LSTM sin confundir "no existe" con un nivel exactamente en el precio.

my @CATEGORIES = qw(
    order_block fvg fibonacci anchored_vwap volume_profile htf_sr bos_choch
    eqh_eql sweep_grab_run supply_demand channels_trendlines
);
my @TIMEFRAMES = (
    [ '1m',  1 ],
    [ '10m', 10 ],
    [ '1h',  60 ],
);
my @HORIZONS = (3, 5, 10, 15);

sub new {
    my ($class, %args) = @_;
    my $pip_size = defined $args{pip_size} ? $args{pip_size} : 0.0001;
    die 'GhostLSTMExtractor: pip_size debe ser positivo' unless _positive($pip_size);
    my $pivot_length = $args{pivot_length} // 20;
    die 'GhostLSTMExtractor: pivot_length debe ser entero >= 1'
        unless defined($pivot_length) && $pivot_length =~ /^\d+$/ && $pivot_length >= 1;
    return bless {
        pip_size       => $pip_size + 0,
        pivot_length   => int($pivot_length),
        atr_period     => int($args{atr_period} // 14),
        volume_ema_len => int($args{volume_ema_len} // 9),
    }, $class;
}

sub csv_columns {
    my ($self) = @_;
    my @columns = qw(
        event_date_utc event_time_utc event_minute_utc event_id ghost_type
        ghost_pivot_price confirmation_index price_hlc3
    );
    for my $tf (@TIMEFRAMES) {
        my $prefix = $tf->[0];
        for my $category (@CATEGORIES) {
            push @columns, map { "${prefix}_${category}_${_}" }
                qw(dist_level_pips dist_range_low_pips dist_range_high_pips available);
        }
    }
    push @columns, qw(atr_14_pips volume volume_ema_9);
    push @columns, map { "target_rastro_next_${_}m" } @HORIZONS;
    return \@columns;
}

# export_csv agrega filas al archivo.  Es seguro llamarlo varias veces: sólo
# escribe cabecera cuando el archivo no contiene datos. Retorna estadísticas.
sub export_csv {
    my ($self, %args) = @_;
    my $candles = $args{candles_1m};
    die 'GhostLSTMExtractor::export_csv: candles_1m debe ser arrayref'
        unless ref($candles) eq 'ARRAY';
    die 'GhostLSTMExtractor::export_csv: output_csv requerido'
        unless defined($args{output_csv}) && length($args{output_csv});
    my $snapshot = $args{level_snapshot};
    die 'GhostLSTMExtractor::export_csv: level_snapshot debe ser coderef'
        unless ref($snapshot) eq 'CODE';
    my $replay_step = $args{replay_step};
    die 'GhostLSTMExtractor::export_csv: replay_step debe ser coderef'
        if defined($replay_step) && ref($replay_step) ne 'CODE';

    _validate_candles($candles);
    my $n = scalar @$candles;
    return { rows_written => 0, trigger_count => 0, skipped_incomplete_target => 0 }
        if !$n;

    # Todas estas series son causales y O(N); jamás se recalculan por evento.
    my $atr = _wilder_atr($candles, $self->{atr_period});
    my $ema = _ema_volume($candles, $self->{volume_ema_len});
    my $aggregates = _aggregate_timeframes($candles, [10, 60]);
    my ($events, $ghost_result) = _ghost_events(
        $candles, $self->{pivot_length}, $args{ghost_detector},
    );
    my $trace_events = _trace_events(
        $events, $args{trace_events}, $ghost_result->{regular_pivots}, $candles,
    );
    my %events_at;
    push @{ $events_at{ $_->{confirmed_at} } }, $_ for @$events;

    my $append = -e $args{output_csv} && -s $args{output_csv};
    open my $fh, '>>', $args{output_csv}
        or die "No se pudo abrir $args{output_csv}: $!";
    print {$fh} _csv_line($self->csv_columns) unless $append;

    my ($written, $triggers, $skipped) = (0, 0, 0);
    for my $i (0 .. $n - 1) {
        my $trigger_events = $events_at{$i} // [];
        # Punto de integración opcional con un motor Replay de datos. El
        # callback recibe sólo el cursor y jamás debe renderizar ni leer una
        # vela posterior; permite actualizar indicadores incrementales.
        $replay_step->({
            visible_index => $i, visible_time => _close_time($candles->[$i]),
            candles_1m => $candles, trigger_count => scalar(@$trigger_events),
            replay_safe => 1,
        }) if $replay_step;
        next unless @$trigger_events;
        $triggers += scalar @$trigger_events;

        # El target de 15m debe estar enteramente en el histórico. No se
        # exportan filas con Y truncado ni se rellena el futuro con ceros.
        my $close_time = _close_time($candles->[$i]);
        if ($close_time + 15 * 60 > _close_time($candles->[-1])) {
            $skipped += scalar @$trigger_events;
            next;
        }

        my $price = _hlc3($candles->[$i]);
        my @feature_values;
        for my $tf (@TIMEFRAMES) {
            my ($label, $minutes) = @$tf;
            my ($tf_candles, $visible_index);
            if ($minutes == 1) {
                ($tf_candles, $visible_index) = ($candles, $i);
            } else {
                $tf_candles = $aggregates->{$minutes};
                $visible_index = _last_closed_index($tf_candles, $close_time);
            }
            my $levels = $snapshot->({
                timeframe       => $label,
                timeframe_min   => $minutes,
                candles         => $tf_candles,
                visible_index   => $visible_index,
                visible_time    => $close_time,
                source_index_1m => $i,
                source_candles_1m => $candles,
                replay_safe     => 1,
            });
            die "level_snapshot no declaro replay_safe para $label en indice $i"
                unless ref($levels) eq 'HASH' && $levels->{replay_safe};
            push @feature_values, _level_features($levels, $price, $self->{pip_size});
        }

        my @targets = map {
            _count_trace_events($trace_events, $close_time, $close_time + $_ * 60)
        } @HORIZONS;
        for my $event (@$trigger_events) {
            my ($date, $time, $minute) = _metadata_time($close_time);
            my @row = (
                $date, $time, $minute, $event->{id}, $event->{type},
                _number($event->{price}), $i, _number($price),
                @feature_values,
                _number($atr->[$i] / $self->{pip_size}),
                _number($candles->[$i]{volume}), _number($ema->[$i]), @targets,
            );
            print {$fh} _csv_line(\@row);
            ++$written;
        }
    }
    close $fh or die "No se pudo cerrar $args{output_csv}: $!";
    return {
        rows_written => $written, trigger_count => $triggers,
        skipped_incomplete_target => $skipped, columns => $self->csv_columns,
    };
}

sub _ghost_events {
    my ($candles, $length, $detector) = @_;
    my $result;
    if ($detector) {
        die 'ghost_detector debe ser coderef' unless ref($detector) eq 'CODE';
        $result = $detector->($candles, $length);
    } else {
        # El detector existente ya expresa la regla Pine: el punto extremo se
        # conserva en index, mientras que confirmed_at indica la vela donde se
        # hizo visible. Por ello los X se toman en confirmed_at, no en index.
        $result = Market::Indicators::PivotMissedReversal->compute(
            candles => $candles, length => $length, show_missed => 1,
        );
    }
    die 'ghost_detector debe devolver hashref con missed_pivots'
        unless ref($result) eq 'HASH' && ref($result->{missed_pivots}) eq 'ARRAY';
    my $events = [ map {
        my %event = %$_;
        # El timestamp de una vela representa su apertura; la señal existe
        # después de su cierre. Esta es la frontera temporal de X e Y.
        $event{emitted_at} = _close_time($candles->[ $event{confirmed_at} ]);
        \%event;
    } sort {
        $a->{confirmed_at} <=> $b->{confirmed_at} || $a->{id} cmp $b->{id}
    } grep {
        defined($_->{confirmed_at}) && $_->{confirmed_at} >= 0
            && $_->{confirmed_at} <= $#$candles && _finite($_->{price})
    } @{ $result->{missed_pivots} } ];
    return wantarray ? ($events, $result) : $events;
}

sub _trace_events {
    my ($ghost_events, $explicit, $regular_pivots, $candles) = @_;
    if (defined $explicit) {
        die 'trace_events debe ser arrayref' unless ref($explicit) eq 'ARRAY';
        return [ sort { $a->{time} <=> $b->{time} } map {
            die 'trace event sin time' unless ref($_) eq 'HASH' && _finite($_->{time});
            { time => $_->{time} + 0 }
        } @$explicit ];
    }
    # Equivalencia por defecto con el rastro confirmado de Pine: en cada vela
    # cerrada posterior a un pivot regular ya confirmado hay un extremo
    # provisional x_last/y_last y se imprime un "1". Es una reconstrucción
    # sólo de datos, sin crear labels Tk/TradingView. Si la UI define otra
    # semántica (por ejemplo, sólo cuando x_last cambia), trace_events permite
    # sustituir esta lista exacta sin cambiar X ni el bucle principal.
    $regular_pivots //= [];
    return [] unless ref($regular_pivots) eq 'ARRAY' && ref($candles) eq 'ARRAY';
    my @regular = sort {
        ($a->{confirmed_at} // -1) <=> ($b->{confirmed_at} // -1)
            || ($a->{index} // -1) <=> ($b->{index} // -1)
    } grep {
        ref($_) eq 'HASH' && defined($_->{confirmed_at}) && defined($_->{index})
    } @$regular_pivots;
    my ($pos, $last, @traces) = (0, undef);
    for my $i (0 .. $#$candles) {
        while ($pos < @regular && $regular[$pos]{confirmed_at} <= $i) {
            $last = $regular[$pos++];
        }
        push @traces, { time => _close_time($candles->[$i]) }
            if $last && $last->{index} < $i;
    }
    return \@traces;
}

sub _level_features {
    my ($levels, $price, $pip_size) = @_;
    my @out;
    for my $category (@CATEGORIES) {
        my $candidate = _nearest_level($levels->{$category}, $price);
        if (!$candidate) {
            push @out, (0, 0, 0, 0);
            next;
        }
        my $level = $candidate->{level};
        my $low   = defined($candidate->{range_low}) ? $candidate->{range_low} : $level;
        my $high  = defined($candidate->{range_high}) ? $candidate->{range_high} : $level;
        ($low, $high) = ($high, $low) if $low > $high;
        # Distancia firmada: positiva significa que el nivel queda arriba de
        # HLC3; negativa, debajo. La direccion queda disponible para LSTM.
        push @out, map { _number(($_ - $price) / $pip_size) } ($level, $low, $high);
        push @out, 1;
    }
    return @out;
}

sub _nearest_level {
    my ($items, $price) = @_;
    return undef unless ref($items) eq 'ARRAY';
    my @valid = grep {
        ref($_) eq 'HASH' && _finite($_->{level})
            && (!defined($_->{range_low}) || _finite($_->{range_low}))
            && (!defined($_->{range_high}) || _finite($_->{range_high}))
    } @$items;
    return undef unless @valid;
    return (sort {
        _distance_to_range($a, $price) <=> _distance_to_range($b, $price)
            || $a->{level} <=> $b->{level}
    } @valid)[0];
}

sub _distance_to_range {
    my ($item, $price) = @_;
    my $low = defined($item->{range_low}) ? $item->{range_low} : $item->{level};
    my $high = defined($item->{range_high}) ? $item->{range_high} : $item->{level};
    ($low, $high) = ($high, $low) if $low > $high;
    return $price < $low ? $low - $price : $price > $high ? $price - $high : 0;
}

sub _aggregate_timeframes {
    my ($candles, $minutes) = @_;
    my %result;
    for my $tf (@$minutes) {
        my $seconds = $tf * 60;
        my (@bars, $current);
        for my $c (@$candles) {
            my $bucket = int($c->{time} / $seconds) * $seconds;
            if (!$current || $current->{time} != $bucket) {
                push @bars, $current if $current;
                $current = {
                    time => $bucket, open => $c->{open}, high => $c->{high},
                    low => $c->{low}, close => $c->{close}, volume => $c->{volume},
                    close_time => $bucket + $seconds,
                };
            } else {
                $current->{high} = $c->{high} if $c->{high} > $current->{high};
                $current->{low} = $c->{low} if $c->{low} < $current->{low};
                $current->{close} = $c->{close};
                $current->{volume} += $c->{volume};
            }
        }
        push @bars, $current if $current;
        $result{$tf} = \@bars;
    }
    return \%result;
}

sub _last_closed_index {
    my ($bars, $time) = @_;
    my ($lo, $hi, $answer) = (0, $#$bars, -1);
    while ($lo <= $hi) {
        my $mid = int(($lo + $hi) / 2);
        if ($bars->[$mid]{close_time} <= $time) {
            $answer = $mid;
            $lo = $mid + 1;
        } else {
            $hi = $mid - 1;
        }
    }
    return $answer;
}

sub _wilder_atr {
    my ($candles, $period) = @_;
    $period = 14 if !$period || $period < 1;
    my (@atr, $previous_close, $value);
    for my $i (0 .. $#$candles) {
        my $c = $candles->[$i];
        my $tr = defined($previous_close)
            ? _max($c->{high} - $c->{low}, abs($c->{high} - $previous_close), abs($c->{low} - $previous_close))
            : $c->{high} - $c->{low};
        $value = !defined($value) ? $tr : (($value * ($period - 1)) + $tr) / $period;
        $atr[$i] = $value;
        $previous_close = $c->{close};
    }
    return \@atr;
}

sub _ema_volume {
    my ($candles, $length) = @_;
    $length = 9 if !$length || $length < 1;
    my $alpha = 2 / ($length + 1);
    my (@out, $ema);
    for my $i (0 .. $#$candles) {
        my $volume = $candles->[$i]{volume};
        $ema = defined($ema) ? $alpha * $volume + (1 - $alpha) * $ema : $volume;
        $out[$i] = $ema;
    }
    return \@out;
}

sub _count_trace_events {
    my ($events, $from, $to) = @_;
    # upper_bound(to) - upper_bound(from) cuenta el intervalo (from, to]
    # en O(log E), sin guardar ni clonar velas futuras por cada evento.
    return _upper_bound_trace($events, $to) - _upper_bound_trace($events, $from);
}
sub _upper_bound_trace {
    my ($events, $time) = @_;
    my ($lo, $hi) = (0, scalar @$events);
    while ($lo < $hi) {
        my $mid = int(($lo + $hi) / 2);
        if ($events->[$mid]{time} <= $time) { $lo = $mid + 1; }
        else                                { $hi = $mid; }
    }
    return $lo;
}

sub _metadata_time {
    my ($epoch) = @_;
    return (strftime('%Y-%m-%d', gmtime($epoch)), strftime('%H:%M:%S', gmtime($epoch)), strftime('%M', gmtime($epoch)));
}
sub _close_time { return $_[0]{close_time} // ($_[0]{time} + 60) }
sub _hlc3 { return ($_[0]{high} + $_[0]{low} + $_[0]{close}) / 3 }
sub _max {
    my $max = shift;
    for (@_) { $max = $_ if $_ > $max; }
    return $max;
}
sub _positive { return _finite($_[0]) && $_[0] > 0 }
sub _number { return _finite($_[0]) ? sprintf('%.10g', $_[0] + 0) : 0 }
sub _finite {
    return defined($_[0]) && !ref($_[0]) && "$_[0]" =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/
        && $_[0] == $_[0] && abs($_[0]) <= 1e300;
}
sub _csv_line {
    my ($fields) = @_;
    return join(',', map {
        my $v = defined($_) ? "$_" : '';
        $v =~ s/"/""/g;
        '"' . $v . '"';
    } @$fields) . "\n";
}
sub _validate_candles {
    my ($candles) = @_;
    for my $i (0 .. $#$candles) {
        my $c = $candles->[$i];
        die "vela 1m $i invalida" unless ref($c) eq 'HASH';
        for my $field (qw(time open high low close volume)) {
            die "vela 1m $i sin $field finito" unless _finite($c->{$field});
        }
        die "vela 1m $i high < low" if $c->{high} < $c->{low};
        die "vela 1m $i volumen negativo" if $c->{volume} < 0;
    }
}

1;
