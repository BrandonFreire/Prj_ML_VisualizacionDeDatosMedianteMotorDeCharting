package Market::Indicators::AnchoredVWAP;

use strict;
use warnings;

# Anchored VWAP Multipivot — Motor de cálculo (Sección 8)
#
# Calcula el Precio Promedio Ponderado por Volumen Anclado reinicializando
# las sumas acumuladas al detectar 5 tipos de eventos/pivots:
#   1. Inicio de Sesión (primer tick/vela del día)
#   2. Apertura de Mercado (hora oficial configurable)
#   3. BOS Confirmado
#   4. CHoCH Confirmado
#   5. POC del Volume Profile

sub new {
    my ($class, %args) = @_;
    return bless {
        std_mult_1         => $args{std_mult_1} // 1.0,
        std_mult_2         => $args{std_mult_2} // 2.0,
        std_mult_3         => $args{std_mult_3} // 3.0,
        band_1_enabled     => exists $args{band_1_enabled} ? $args{band_1_enabled} : 1,
        band_2_enabled     => exists $args{band_2_enabled} ? $args{band_2_enabled} : 1,
        band_3_enabled     => exists $args{band_3_enabled} ? $args{band_3_enabled} : 0,
        # manual conserva la herramienta de dibujo. multipivot incorpora los
        # cinco anclajes analíticos exigidos por la Fase 2.
        anchor_mode        => $args{anchor_mode} // 'manual',
        session_open_hour   => $args{session_open_hour}   // 0,
        session_open_minute => $args{session_open_minute} // 0,

        _manual_anchors    => [],
        _vwap_lines        => [],     # [{anchor_idx, values => [vwap_i], std_dev => [std_i]}]
        _candles           => undef,
        _smc_ref           => undef,
        _vp_ref            => undef,  # VolumeProfile indicator
        _pivot_ref         => undef,  # PivotMissedReversal para AVWAP automático
        _auto_missed_result=> undef,
    }, $class;
}

sub set_smc_indicator {
    my ($self, $smc) = @_;
    $self->{_smc_ref} = $smc;
}

sub set_vp_indicator {
    my ($self, $vp) = @_;
    $self->{_vp_ref} = $vp;
}

sub set_pivot_missed_indicator {
    my ($self, $pivot) = @_;
    $self->{_pivot_ref} = $pivot;
}

sub reset {
    my ($self) = @_;
    @{ $self->{_vwap_lines} } = () if $self->{_vwap_lines};
    $self->{_candles}    = undef;
    $self->{_auto_missed_result} = undef;
}

sub add_manual_anchor {
    my ($self, $idx) = @_;
    return unless defined $idx;
    push @{ $self->{_manual_anchors} }, { index => int($idx) };
}

sub clear_manual_anchors {
    my ($self) = @_;
    $self->{_manual_anchors} = [];
}

sub set_anchor_mode {
    my ($self, $mode) = @_;
    return unless defined $mode && $mode =~ /^(?:manual|multipivot)$/;
    $self->{anchor_mode} = $mode;
}

sub get_anchor_mode { return $_[0]->{anchor_mode} }

# Configuración equivalente a los multiplicadores de bandas de TradingView.
# Puede llamarse desde un diálogo Tk sin recalcular la arquitectura del overlay:
#   $vwap->set_band_configuration(1, enabled => 1, multiplier => 1.0);
#   $vwap->set_band_configuration(2, enabled => 1, multiplier => 2.0);
sub set_band_configuration {
    my ($self, $number, %args) = @_;
    return unless defined $number && $number =~ /^[123]$/;

    my $mult_key = "std_mult_$number";
    my $enabled_key = "band_${number}_enabled";
    if (exists $args{multiplier} && defined $args{multiplier}) {
        my $mult = $args{multiplier} + 0;
        return if $mult < 0;
        $self->{$mult_key} = $mult;
    }
    $self->{$enabled_key} = $args{enabled} ? 1 : 0 if exists $args{enabled};
}

sub get_band_configuration {
    my ($self, $number) = @_;
    return unless defined $number && $number =~ /^[123]$/;
    return {
        enabled    => $self->{"band_${number}_enabled"} ? 1 : 0,
        multiplier => $self->{"std_mult_$number"},
    };
}

sub compute_all {
    my ($self, $market) = @_;
    $self->reset();

    my $arr = $market->_active_array();
    $self->{_candles} = $arr;
    my $n = scalar @$arr;
    return if $n < 2;

    # 1. Recopilar anclajes. En manual sólo se usan clics del usuario; en
    # multipivot se añaden Inicio de Sesión, Apertura, BOS, CHoCH y POC.
    my @anchors = $self->_collect_anchors($arr);

    # 2. Ordenar por índice y eliminar duplicados
    @anchors = sort { $a->{index} <=> $b->{index} } @anchors;
    my %seen;
    @anchors = grep { !$seen{$_->{index}}++ } @anchors;

    # 3. Un VWAP manual continúa independiente hacia el final. En modo
    # multipivot cada pivote reinicia estrictamente la acumulación, por lo que
    # el tramo termina justo antes del siguiente pivote.
    my @vwap_lines;
    for my $ai (0 .. $#anchors) {
        my $anchor = $anchors[$ai];
        my $start  = $anchor->{index};
        my $end = $self->{anchor_mode} eq 'multipivot' && $ai < $#anchors
            ? $anchors[$ai + 1]{index} - 1
            : $n - 1;
        next if $start > $end || $start < 0;

        my @values  = (undef) x $n;
        my @std_dev = (undef) x $n;
        my ($cum_vol, $cum_pv, $cum_pv2) = (0, 0, 0);

        for my $i ($start .. $end) {
            my $c = $arr->[$i];
            next unless defined $c->{high} && defined $c->{low}
                     && defined $c->{close} && defined $c->{volume};

            my $typical = ($c->{high} + $c->{low} + $c->{close}) / 3.0;
            $cum_vol += $c->{volume};
            $cum_pv  += $typical * $c->{volume};
            $cum_pv2 += ($typical * $typical) * $c->{volume};

            if ($cum_vol > 0) {
                my $vwap = $cum_pv / $cum_vol;
                $values[$i] = $vwap;

                my $variance = ($cum_pv2 / $cum_vol) - ($vwap * $vwap);
                $variance = 0 if $variance < 0; # Prevenir errores de coma flotante
                $std_dev[$i] = sqrt($variance);
            }
        }

        push @vwap_lines, {
            anchor_idx   => $start,
            end_idx      => $end,
            anchor_source => $anchor->{source} // 'manual',
            values       => \@values,
            std_dev      => \@std_dev,
            mult_1       => $self->{std_mult_1},
            mult_2       => $self->{std_mult_2},
            mult_3       => $self->{std_mult_3},
            band_1_enabled => $self->{band_1_enabled} ? 1 : 0,
            band_2_enabled => $self->{band_2_enabled} ? 1 : 0,
            band_3_enabled => $self->{band_3_enabled} ? 1 : 0,
        };
    }

    # El AVWAP de missed pivot es independiente del modo manual/multipivot:
    # solo existe tras la confirmación del último evento y se recalcula desde
    # su vela extrema. No añade ni conserva instancias históricas obsoletas.
    if (my $pivot = $self->{_pivot_ref}) {
        my $events = $pivot->can('get_missed_pivots') ? $pivot->get_missed_pivots() : [];
        my $auto = $self->compute_missed_pivot_auto(
            candles => $arr, missed_pivot_events => $events,
        );
        $self->{_auto_missed_result} = $auto;
        push @vwap_lines, $auto->{line} if $auto->{visible} && $auto->{line};
    }

    @{ $self->{_vwap_lines} } = @vwap_lines;
}

# Construye una única instancia desde el missed pivot confirmado más reciente.
# El tramo comienza en la vela del extremo, pero no se expone hasta que su
# confirmationIndex ya pertenece al cursor visible. Así se conserva la
# geometría histórica sin adelantar una señal al Replay.
sub compute_missed_pivot_auto {
    my ($class_or_self, %args) = @_;
    my $self = ref($class_or_self) ? $class_or_self : $class_or_self->new(%args);
    my $candles = $args{candles} // [];
    die 'AnchoredVWAP::compute_missed_pivot_auto: candles debe ser un arrayref'
        unless ref($candles) eq 'ARRAY';
    my $max_idx = defined $args{max_visible_index} ? int($args{max_visible_index}) : $#$candles;
    $max_idx = $#$candles if $max_idx > $#$candles;
    return {
        visible => 0, reason => 'no_candles', line => undef,
        selected_event => undef, replay_safe => 1,
    } if $max_idx < 0;

    my $event = _latest_confirmed_missed_pivot(
        $args{missed_pivot_events} // $args{events} // [], $candles, $max_idx,
    );
    return {
        visible => 0, reason => 'no_confirmed_missed_pivot', line => undef,
        selected_event => undef, replay_safe => 1,
    } unless $event;

    my $line = $self->_build_auto_missed_line($candles, $max_idx, $event);
    return {
        visible => $line ? 1 : 0,
        reason => $line ? undef : 'no_valid_vwap_points',
        line => $line, selected_event => { %$event }, replay_safe => 1,
    };
}

sub _build_auto_missed_line {
    my ($self, $candles, $max_idx, $event) = @_;
    my $start = $event->{index};
    return undef unless defined($start) && $start >= 0 && $start <= $max_idx;
    # La serie resultante no reserva índices posteriores al cursor: incluso
    # valores undef revelarían la longitud futura a un consumidor de Replay.
    my $n = $max_idx + 1;
    my (@values, @std_dev);
    $#values = $#std_dev = $n - 1 if $n;
    my ($weight, $mean, $m2, $last) = (0, 0, 0, undef);
    for my $i ($start .. $max_idx) {
        my $c = $candles->[$i] // next;
        next unless defined($c->{high}) && defined($c->{low}) && defined($c->{close})
                 && defined($c->{volume}) && $c->{volume} > 0;
        my $price = ($c->{high} + $c->{low} + $c->{close}) / 3;
        my $new_weight = $weight + $c->{volume};
        my $delta = $price - $mean;
        my $next_mean = $mean + $c->{volume} / $new_weight * $delta;
        $m2 += $c->{volume} * $delta * ($price - $next_mean);
        ($weight, $mean) = ($new_weight, $next_mean);
        my $variance = $weight > 0 ? $m2 / $weight : 0;
        $variance = 0 if $variance < 0 && $variance > -1e-12;
        my $deviation = $variance > 0 ? sqrt($variance) : 0;
        $values[$i] = $mean + 0;
        $std_dev[$i] = $deviation + 0;
        $last = $i;
    }
    return undef unless defined $last;

    return {
        id           => join('_', 'auto_missed_vwap', $event->{id}, $event->{index}, $event->{confirmed_at}),
        anchor_idx   => $start,
        end_idx      => $last,
        anchor_source => 'missed_pivot_auto',
        source_event_id => $event->{id},
        missed_pivot_id  => $event->{id},
        pivot_type       => $event->{pivotType} // $event->{type},
        pivot_price      => $event->{price} + 0,
        pivot_time       => $event->{pivotTime} // $event->{time},
        confirmation_index => $event->{confirmationIndex} // $event->{confirmed_at},
        confirmation_time  => $event->{confirmationTime} // $event->{confirmed_time},
        confirmed      => 1,
        values         => \@values,
        std_dev        => \@std_dev,
        mult_1         => $self->{std_mult_1},
        mult_2         => $self->{std_mult_2},
        mult_3         => $self->{std_mult_3},
        band_1_enabled => $self->{band_1_enabled} ? 1 : 0,
        band_2_enabled => $self->{band_2_enabled} ? 1 : 0,
        band_3_enabled => $self->{band_3_enabled} ? 1 : 0,
        replay_safe    => 1,
    };
}

sub _latest_confirmed_missed_pivot {
    my ($events, $candles, $max_idx) = @_;
    return undef unless ref($events) eq 'ARRAY';
    my @eligible;
    for my $event (@$events) {
        next unless ref($event) eq 'HASH';
        next unless ($event->{kind} // '') eq 'missedPivot';
        next unless $event->{confirmed};
        my $kind = $event->{pivotType} // $event->{type} // '';
        next unless $kind eq 'high' || $kind eq 'low';
        my $index = $event->{index};
        my $confirmed_at = $event->{confirmationIndex} // $event->{confirmed_at};
        next unless defined($index) && $index =~ /^\d+$/
                 && defined($confirmed_at) && $confirmed_at =~ /^\d+$/;
        next if $index > $max_idx || $confirmed_at > $max_idx || $confirmed_at < $index;
        next unless defined($candles->[$index]);
        push @eligible, {
            %$event, index => int($index), confirmed_at => int($confirmed_at),
            confirmationIndex => int($confirmed_at), pivotType => $kind,
            id => $event->{id} // join('_', 'missed_pivot', $kind, $index, $confirmed_at),
        };
    }
    return undef unless @eligible;
    @eligible = sort {
        $b->{confirmed_at} <=> $a->{confirmed_at}
            || $b->{index} <=> $a->{index}
            || $b->{id} cmp $a->{id}
    } @eligible;
    return $eligible[0];
}

sub _collect_anchors {
    my ($self, $arr) = @_;
    my @anchors = map { { index => $_->{index}, source => 'manual' } }
                  @{ $self->{_manual_anchors} // [] };
    return @anchors unless ($self->{anchor_mode} // 'manual') eq 'multipivot';

    my $n = scalar @$arr;
    return @anchors unless $n;

    # Inicio de cada sesión y apertura configurada del mercado.
    my $open_seconds = 3600 * $self->{session_open_hour}
                     + 60   * $self->{session_open_minute};
    my $last_session;
    for my $i (0 .. $n - 1) {
        my $time = $arr->[$i]{time};
        next unless defined $time;
        my $session = int(($time - $open_seconds) / 86400);
        if (!defined $last_session || $session != $last_session) {
            push @anchors, { index => $i, source => 'session_start' };
            $last_session = $session;
        }
        my $day_seconds = $time % 86400;
        push @anchors, { index => $i, source => 'market_open' }
            if $day_seconds == $open_seconds;
    }

    # Velas exactas de confirmación de estructura.
    my $smc = $self->{_smc_ref};
    if ($smc) {
        for my $method (qw(get_bos_events get_choch_events)) {
            next unless $smc->can($method);
            my $source = $method eq 'get_bos_events' ? 'bos' : 'choch';
            push @anchors, map {
                { index => ($_->{confirmed_at} // $_->{index}), source => $source }
            } @{ $smc->$method() // [] };
        }
    }

    # POC temporal calculado por VolumeProfile (vela con típico más cercano
    # al nodo de máximo volumen).
    my $vp = $self->{_vp_ref};
    if ($vp && $vp->can('get_profiles')) {
        push @anchors, map {
            defined $_->{poc_index}
                ? ({ index => $_->{poc_index}, source => 'poc' }) : ()
        } @{ $vp->get_profiles() // [] };
    }

    return grep { defined $_->{index} && $_->{index} >= 0 && $_->{index} < $n } @anchors;
}



# ================================================================
# Accessors
# ================================================================
sub get_vwap_lines { return $_[0]->{_vwap_lines} }
sub get_auto_missed_result { return $_[0]->{_auto_missed_result} }



1;
