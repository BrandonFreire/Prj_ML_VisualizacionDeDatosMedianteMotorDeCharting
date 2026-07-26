package Market::Indicators::VolumeProfile;

use strict;
use warnings;

# Perfil de Volumen Avanzado — Motor de cálculo (Sección 7)
#
# Proyecta horizontalmente POC (Point of Control), VAH (Value Area High)
# y VAL (Value Area Low) usando tres modos operativos de anclaje:
#   1. Por Sesión — segmentado por apertura cronológica
#   2. Por BOS/CHoCH — anclado a eventos confirmados en HTF
#   3. Contingencia — pasado lejano sin datos recientes

my $DEFAULT_BINS       = 50;    # resolución del histograma
my $VALUE_AREA_PCT     = 0.70;  # 70% del volumen total para Value Area

sub new {
    my ($class, %args) = @_;
    my $num_bins = $args{num_bins} // $DEFAULT_BINS;
    my $value_area_pct = $args{value_area_pct} // $VALUE_AREA_PCT;
    die 'VolumeProfile::new: num_bins debe ser un entero positivo'
        unless defined($num_bins) && $num_bins =~ /^\d+$/ && $num_bins > 0;
    die 'VolumeProfile::new: value_area_pct debe estar en (0, 1]'
        unless _finite($value_area_pct) && $value_area_pct > 0 && $value_area_pct <= 1;
    return bless {
        # El perfil sólo existe cuando el usuario dibuja un anclaje.  No se
        # generan perfiles de sesión/globales como efecto de compute_all().
        mode           => $args{mode} // 'manual',
        num_bins       => $num_bins + 0,
        value_area_pct => $value_area_pct + 0,
        session_open_hour   => $args{session_open_hour}   // 0,
        session_open_minute => $args{session_open_minute} // 0,
        contingency_bars    => $args{contingency_bars}    // 500,

        _manual_anchors => [],
        _profiles      => [],
        _profile_cache => {},
        _candles       => undef,
        _smc_ref       => undef,
    }, $class;
}

sub set_smc_indicator {
    my ($self, $smc) = @_;
    $self->{_smc_ref} = $smc;
    $self->{_profile_cache} = {};
}

sub reset {
    my ($self) = @_;
    @{ $self->{_profiles} } = () if $self->{_profiles};
    $self->{_profile_cache} = {};
    $self->{_candles}  = undef;
}

sub add_manual_anchor {
    my ($self, $start_idx, $end_idx) = @_;
    return unless defined($start_idx) && !ref($start_idx) && $start_idx =~ /^\d+$/;
    return if defined($end_idx) && (ref($end_idx) || $end_idx !~ /^\d+$/);

    # end_idx indefinido representa un perfil anclado "desde esta vela hasta
    # la última vela disponible".  Un end_idx explícito representa Fixed Range.
    push @{ $self->{_manual_anchors} }, {
        start  => int($start_idx),
        end    => defined $end_idx ? int($end_idx) : undef,
        source => 'manual',
    };
    $self->{_profile_cache} = {};
}

sub clear_manual_anchors {
    my ($self) = @_;
    $self->{_manual_anchors} = [];
    $self->{_profile_cache} = {};
}

sub set_mode {
    my ($self, $mode) = @_;
    return unless defined $mode && $mode =~ /^(?:manual|session|bos_choch|contingency)$/;
    $self->{mode} = $mode;
    $self->{_profile_cache} = {};
}

sub get_mode { return $_[0]->{mode} }

sub compute_all {
    my ($self, $market) = @_;
    $self->reset();

    my $arr = $market->get_active_candles();
    $self->{_candles} = $arr;
    my $n = scalar @$arr;
    return if $n < 2;

    my @segments = $self->_segments_for_mode($arr);
    # Estrictamente manual: sin un anclaje no hay nada que calcular/renderizar.
    return unless @segments;

    # Calcular perfil para cada segmento
    my @profiles;
    for my $seg (@segments) {
        my $start = $seg->{start};
        my $end   = defined $seg->{end} ? $seg->{end} : $n - 1;
        my $profile = $self->_compute_profile($arr, $start, $end);
        next unless $profile;
        $profile->{open_ended} = !defined $seg->{end};
        $profile->{source} = $seg->{source} // $self->{mode};
        push @profiles, $profile;
    }

    @{ $self->{_profiles} } = @profiles;
}

# Selecciona segmentos sin mezclar los modos automáticos con la herramienta
# manual. Los modos session/bos_choch/contingency sólo se activan si el caller
# los selecciona con set_mode(), por lo que la UI no vuelve a dibujar perfiles
# globales inesperados.
sub _segments_for_mode {
    my ($self, $arr) = @_;
    my $mode = $self->{mode} // 'manual';
    my $n = scalar @$arr;

    if ($mode eq 'manual') {
        return @{ $self->{_manual_anchors} // [] };
    }

    if ($mode eq 'session') {
        my @segments;
        my $open_seconds = 3600 * $self->{session_open_hour}
                         + 60   * $self->{session_open_minute};
        my ($start, $last_session);
        for my $i (0 .. $n - 1) {
            my $time = $arr->[$i]{time};
            next unless defined $time;
            my $session = int(($time - $open_seconds) / 86400);
            if (!defined $last_session || $session != $last_session) {
                push @segments, { start => $start, end => $i - 1, source => 'session' }
                    if defined $start && $i > $start;
                $start = $i;
                $last_session = $session;
            }
        }
        push @segments, { start => $start, end => $n - 1, source => 'session' }
            if defined $start && $start < $n;
        return @segments;
    }

    if ($mode eq 'bos_choch') {
        my $smc = $self->{_smc_ref};
        my @events;
        if ($smc) {
            push @events, @{ $smc->get_bos_events()   // [] } if $smc->can('get_bos_events');
            push @events, @{ $smc->get_choch_events() // [] } if $smc->can('get_choch_events');
        }
        # Sólo estructura externa: representa los pivotes macro disponibles
        # para la temporalidad activa.
        my %seen;
        my @starts = sort { $a <=> $b }
            grep { $_ >= 0 && $_ < $n && !$seen{$_}++ }
            map { $_->{confirmed_at} // $_->{index} }
            grep { ($_->{scope} // 'internal') eq 'external' } @events;
        return $self->_contingency_segments($n) unless @starts;
        unshift @starts, 0 if $starts[0] != 0;
        my @segments;
        for my $i (0 .. $#starts) {
            my $end = $i < $#starts ? $starts[$i + 1] - 1 : $n - 1;
            push @segments, { start => $starts[$i], end => $end, source => 'bos_choch' }
                if $starts[$i] <= $end;
        }
        return @segments;
    }

    return $mode eq 'contingency' ? $self->_contingency_segments($n) : ();
}

sub _contingency_segments {
    my ($self, $n) = @_;
    return () unless $n;
    my $bars = $self->{contingency_bars} // 500;
    $bars = 2 if $bars < 2;
    my $start = $n - $bars;
    $start = 0 if $start < 0;
    return ({ start => $start, end => $n - 1, source => 'contingency' });
}

# ================================================================
# Cálculo del perfil de volumen para un segmento
# ================================================================
sub _compute_profile {
    my ($self, $arr, $start, $end) = @_;
    return undef if $start > $end;
    return undef if $start < 0 || $end >= scalar @$arr;

    my $num_bins = $self->{num_bins};
    my $va_pct   = $self->{value_area_pct};

    # Encontrar rango de precio del segmento
    my ($price_min, $price_max) = ($arr->[$start]{low}, $arr->[$start]{high});
    for my $i ($start .. $end) {
        my $c = $arr->[$i];
        $price_min = $c->{low}  if defined $c->{low}  && $c->{low}  < $price_min;
        $price_max = $c->{high} if defined $c->{high} && $c->{high} > $price_max;
    }

    my $flat_price;
    if ($price_max <= $price_min) {
        $flat_price = $price_min + 0;
        my $padding = abs($flat_price) * 1e-9;
        $padding = 1e-9 if $padding < 1e-9;
        $price_min -= $padding / 2;
        $price_max += $padding / 2;
    }
    my $range    = $price_max - $price_min;
    my $bin_size = $range / $num_bins;
    return undef if $bin_size <= 0;

    # Inicializar bins
    my @bins;
    for my $b (0 .. $num_bins - 1) {
        push @bins, {
            price_low   => $price_min + $b * $bin_size,
            price_high  => $price_min + ($b + 1) * $bin_size,
            price       => $price_min + ($b + 0.5) * $bin_size,
            volume      => 0,
            up_volume   => 0,   # volumen comprador (close >= open)
            down_volume => 0,   # volumen vendedor  (close <  open)
        };
    }

    # Distribuir volumen de cada vela proporcionalmente a sus bins
    my $total_vol = 0;
    for my $i ($start .. $end) {
        my $c = $arr->[$i];
        next unless defined $c->{high} && defined $c->{low} && defined $c->{volume};
        my $vol = $c->{volume};
        next if $vol <= 0;

        # Clasificar vela como compradora o vendedora
        my $is_up = (defined $c->{close} && defined $c->{open}
                     && $c->{close} >= $c->{open}) ? 1 : 0;

        my $c_range = $c->{high} - $c->{low};

        # Una vela sin rango sigue aportando todo su volumen al nivel negociado;
        # repartir por overlap asignaba cero y hacía inconsistente total_vol.
        if ($c_range <= 0) {
            my $bin = int(($c->{low} - $price_min) / $bin_size);
            $bin = 0 if $bin < 0;
            $bin = $num_bins - 1 if $bin >= $num_bins;
            $bins[$bin]{volume} += $vol;
            if ($is_up) { $bins[$bin]{up_volume}   += $vol; }
            else        { $bins[$bin]{down_volume} += $vol; }
            $total_vol += $vol;
            next;
        }

        # Bins que cubre esta vela
        my $first_bin = int(($c->{low}  - $price_min) / $bin_size);
        my $last_bin  = int(($c->{high} - $price_min) / $bin_size);
        $first_bin = 0 if $first_bin < 0;
        $last_bin  = $num_bins - 1 if $last_bin >= $num_bins;

        for my $b ($first_bin .. $last_bin) {
            # Fracción de overlap entre la vela y el bin
            my $overlap_low  = $bins[$b]{price_low}  > $c->{low}  ? $bins[$b]{price_low}  : $c->{low};
            my $overlap_high = $bins[$b]{price_high} < $c->{high} ? $bins[$b]{price_high} : $c->{high};
            my $overlap = $overlap_high - $overlap_low;
            $overlap = 0 if $overlap < 0;

            my $frac = $overlap / $c_range;
            my $contrib = $vol * $frac;
            $bins[$b]{volume} += $contrib;
            if ($is_up) { $bins[$b]{up_volume}   += $contrib; }
            else        { $bins[$b]{down_volume} += $contrib; }
        }
        $total_vol += $vol;
    }

    return undef if $total_vol <= 0;

    # POC = bin con mayor volumen
    my $poc_bin = 0;
    for my $b (1 .. $#bins) {
        $poc_bin = $b if $bins[$b]{volume} > $bins[$poc_bin]{volume};
    }
    my $poc = defined($flat_price) ? $flat_price : $bins[$poc_bin]{price};

    # Value Area: expandir desde el POC hasta cubrir el 70% del volumen
    my $va_target = $total_vol * $va_pct;
    my $va_vol    = $bins[$poc_bin]{volume};
    my ($va_low_bin, $va_high_bin) = ($poc_bin, $poc_bin);

    while ($va_vol < $va_target && ($va_low_bin > 0 || $va_high_bin < $#bins)) {
        my $try_low  = $va_low_bin  > 0     ? $bins[$va_low_bin  - 1]{volume} : -1;
        my $try_high = $va_high_bin < $#bins ? $bins[$va_high_bin + 1]{volume} : -1;

        if ($try_high >= $try_low) {
            $va_high_bin++;
            $va_vol += $bins[$va_high_bin]{volume};
        } else {
            $va_low_bin--;
            $va_vol += $bins[$va_low_bin]{volume};
        }
    }

    my $vah = $bins[$va_high_bin]{price_high};
    my $val = $bins[$va_low_bin]{price_low};

    # El POC es un precio, no un índice de bin. Para que AnchoredVWAP pueda
    # usarlo como pivote temporal escogemos la vela del segmento cuyo precio
    # típico está más cerca del nodo POC.
    my ($poc_index, $poc_distance);
    for my $i ($start .. $end) {
        my $c = $arr->[$i];
        next unless defined $c->{high} && defined $c->{low} && defined $c->{close};
        my $typical = ($c->{high} + $c->{low} + $c->{close}) / 3.0;
        my $distance = abs($typical - $poc);
        if (!defined $poc_distance || $distance < $poc_distance) {
            ($poc_index, $poc_distance) = ($i, $distance);
        }
    }

    return {
        start_idx => $start,
        end_idx   => $end,
        bins      => \@bins,
        poc       => $poc,
        poc_index => $poc_index,           # vela temporal más próxima al nodo POC
        vah       => $vah,
        val       => $val,
        total_vol => $total_vol,
        max_vol   => $bins[$poc_bin]{volume},
    };
}

# ================================================================
# Accessors
# ================================================================
sub get_profiles   { return $_[0]->{_profiles} }

# Devuelve perfiles recalculados únicamente con las velas disponibles hasta
# max_visible_index. Recortar sólo el dibujo no es suficiente: POC/VAH/VAL y
# los bins también deben ignorar el futuro durante Replay.
sub get_profiles_at {
    my ($self, $max_visible_index) = @_;
    my $candles = $self->{_candles} // [];
    return [] unless @$candles;

    $max_visible_index = $#$candles unless defined $max_visible_index;
    die 'VolumeProfile::get_profiles_at: max_visible_index debe ser un entero no negativo'
        unless !ref($max_visible_index) && $max_visible_index =~ /^\d+$/;
    $max_visible_index = int($max_visible_index);
    $max_visible_index = $#$candles if $max_visible_index > $#$candles;

    return $self->{_profiles} if $max_visible_index == $#$candles;
    return $self->{_profile_cache}{$max_visible_index}
        if exists $self->{_profile_cache}{$max_visible_index};

    my @prefix = @$candles[0 .. $max_visible_index];
    my @segments = $self->_segments_for_mode(\@prefix);
    my @profiles;
    for my $seg (@segments) {
        my $start = $seg->{start};
        next unless defined($start) && $start >= 0 && $start <= $max_visible_index;

        my $declared_end = $seg->{end};
        my $end = defined($declared_end) ? $declared_end : $max_visible_index;
        $end = $max_visible_index if $end > $max_visible_index;
        next if $start > $end;

        my $profile = $self->_compute_profile(\@prefix, $start, $end);
        next unless $profile;
        $profile->{open_ended} = !defined $declared_end;
        $profile->{truncated_by_cursor} = 1
            if defined($declared_end) && $declared_end > $max_visible_index;
        $profile->{source} = $seg->{source} // $self->{mode};
        push @profiles, $profile;
    }

    $self->{_profile_cache}{$max_visible_index} = \@profiles;
    return $self->{_profile_cache}{$max_visible_index};
}

# Devuelve el perfil más reciente (para anclaje VWAP)
sub get_latest_profile {
    my ($self) = @_;
    my $profiles = $self->{_profiles} // [];
    return undef unless @$profiles;
    return $profiles->[-1];
}

# Devuelve el POC del perfil más reciente
sub get_poc {
    my ($self) = @_;
    my $p = $self->get_latest_profile();
    return defined $p ? $p->{poc} : undef;
}

sub get_poc_index {
    my ($self) = @_;
    my $p = $self->get_latest_profile();
    return defined $p ? $p->{poc_index} : undef;
}

sub _finite {
    my ($value) = @_;
    return defined($value) && !ref($value)
        && "$value" =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/
        && $value == $value && abs($value) <= 1e300;
}

1;
