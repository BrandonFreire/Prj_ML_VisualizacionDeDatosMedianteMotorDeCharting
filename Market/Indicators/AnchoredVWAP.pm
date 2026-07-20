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
        _vwap_cache        => {},
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
    $self->{_vwap_cache} = {};
}

sub set_vp_indicator {
    my ($self, $vp) = @_;
    $self->{_vp_ref} = $vp;
    $self->{_vwap_cache} = {};
}

sub set_pivot_missed_indicator {
    my ($self, $pivot) = @_;
    $self->{_pivot_ref} = $pivot;
    $self->{_vwap_cache} = {};
}

sub reset {
    my ($self) = @_;
    @{ $self->{_vwap_lines} } = () if $self->{_vwap_lines};
    $self->{_vwap_cache} = {};
    $self->{_candles}    = undef;
    $self->{_auto_missed_result} = undef;
}

sub add_manual_anchor {
    my ($self, $idx) = @_;
    return unless defined($idx) && !ref($idx) && $idx =~ /^\d+$/;
    push @{ $self->{_manual_anchors} }, { index => int($idx) };
    $self->{_vwap_cache} = {};
}

sub clear_manual_anchors {
    my ($self) = @_;
    $self->{_manual_anchors} = [];
    $self->{_vwap_cache} = {};
}

sub set_anchor_mode {
    my ($self, $mode) = @_;
    return unless defined $mode && $mode =~ /^(?:manual|multipivot)$/;
    $self->{anchor_mode} = $mode;
    $self->{_vwap_cache} = {};
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
        return unless _finite($args{multiplier});
        my $mult = $args{multiplier} + 0;
        return if $mult < 0;
        $self->{$mult_key} = $mult;
    }
    $self->{$enabled_key} = $args{enabled} ? 1 : 0 if exists $args{enabled};
    $self->{_vwap_cache} = {};
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

    my ($lines, $auto) = $self->_calculate_lines($arr);
    $self->{_vwap_lines} = $lines;
    $self->{_auto_missed_result} = $auto;
}

sub _calculate_lines {
    my ($self, $arr) = @_;
    my $n = scalar @$arr;
    return ([], undef) if $n < 2;

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

        # En multipivot los tramos son consecutivos y normalmente cortos. No
        # reservar dos arreglos del tamaño total por cada BOS/CHoCH evita un
        # crecimiento cuadrático de memoria en historiales largos.
        my $compact = $self->{anchor_mode} eq 'multipivot' ? 1 : 0;
        my @values  = $compact ? () : ((undef) x $n);
        my @std_dev = $compact ? () : ((undef) x $n);
        my ($weight, $mean, $m2) = (0, 0, 0);

        for my $i ($start .. $end) {
            my $c = $arr->[$i];
            next unless _valid_vwap_candle($c);

            my $typical = ($c->{high} + $c->{low} + $c->{close}) / 3.0;
            my $new_weight = $weight + $c->{volume};
            my $delta = $typical - $mean;
            my $next_mean = $mean + $c->{volume} / $new_weight * $delta;
            $m2 += $c->{volume} * $delta * ($typical - $next_mean);
            ($weight, $mean) = ($new_weight, $next_mean);
            my $variance = $m2 / $weight;
            $variance = 0 if $variance < 0 && $variance > -1e-12;
            my $slot = $compact ? $i - $start : $i;
            $values[$slot] = $mean + 0;
            $std_dev[$slot] = $variance > 0 ? sqrt($variance) : 0;
        }

        push @vwap_lines, {
            anchor_idx   => $start,
            end_idx      => $end,
            values_offset => $compact ? $start : 0,
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
    my $auto_result;
    if (my $pivot = $self->{_pivot_ref}) {
        my $events = $pivot->can('get_missed_pivots') ? $pivot->get_missed_pivots() : [];
        my $auto = $self->compute_missed_pivot_auto(
            candles => $arr, missed_pivot_events => $events,
        );
        $auto_result = $auto;
        push @vwap_lines, $auto->{line} if $auto->{visible} && $auto->{line};
    }

    return (\@vwap_lines, $auto_result);
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
    die 'AnchoredVWAP::compute_missed_pivot_auto: max_visible_index debe ser un entero'
        if defined($args{max_visible_index}) && $args{max_visible_index} !~ /^-?\d+$/;
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
        next unless _valid_vwap_candle($c);
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
        next unless _finite($event->{price});
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
    if ($vp && ($vp->can('get_profiles_at') || $vp->can('get_profiles'))) {
        my $profiles = $vp->can('get_profiles_at')
            ? $vp->get_profiles_at($#$arr)
            : $vp->get_profiles();
        push @anchors, map {
            defined $_->{poc_index}
                ? ({ index => $_->{poc_index}, source => 'poc' }) : ()
        } @{ $profiles // [] };
    }

    return grep { defined $_->{index} && $_->{index} >= 0 && $_->{index} < $n } @anchors;
}



# ================================================================
# Accessors
# ================================================================
sub get_vwap_lines { return $_[0]->{_vwap_lines} }
sub get_auto_missed_result { return $_[0]->{_auto_missed_result} }

# Reconstruye anclas y líneas con el prefijo disponible en Replay. Esto no se
# limita a cortar coordenadas: también selecciona el último missed pivot y el
# POC que realmente existían en ese cursor.
sub get_vwap_lines_at {
    my ($self, $max_visible_index) = @_;
    my $candles = $self->{_candles} // [];
    return [] unless @$candles;

    $max_visible_index = $#$candles unless defined $max_visible_index;
    die 'AnchoredVWAP::get_vwap_lines_at: max_visible_index debe ser un entero no negativo'
        unless !ref($max_visible_index) && $max_visible_index =~ /^\d+$/;
    $max_visible_index = int($max_visible_index);
    $max_visible_index = $#$candles if $max_visible_index > $#$candles;

    return $self->{_vwap_lines} if $max_visible_index == $#$candles;
    return $self->{_vwap_cache}{$max_visible_index}
        if exists $self->{_vwap_cache}{$max_visible_index};

    my @prefix = @$candles[0 .. $max_visible_index];
    my ($lines) = $self->_calculate_lines(\@prefix);
    $self->{_vwap_cache}{$max_visible_index} = $lines;
    return $self->{_vwap_cache}{$max_visible_index};
}

sub _valid_vwap_candle {
    my ($candle) = @_;
    return 0 unless ref($candle) eq 'HASH';
    return 0 unless !grep { !_finite($candle->{$_}) } qw(high low close volume);
    return 0 if $candle->{high} < $candle->{low} || $candle->{volume} <= 0;
    return 1;
}

sub _finite {
    my ($value) = @_;
    return defined($value) && !ref($value)
        && "$value" =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/
        && $value == $value && abs($value) <= 1e300;
}



1;
