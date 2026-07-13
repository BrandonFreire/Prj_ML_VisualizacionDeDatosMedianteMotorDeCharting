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
    return bless {
        mode           => 'manual',
        num_bins       => $args{num_bins}       // $DEFAULT_BINS,
        value_area_pct => $args{value_area_pct} // $VALUE_AREA_PCT,

        _manual_anchors => [],
        _profiles      => [],
        _candles       => undef,
        _smc_ref       => undef,
    }, $class;
}

sub set_smc_indicator {
    my ($self, $smc) = @_;
    $self->{_smc_ref} = $smc;
}

sub reset {
    my ($self) = @_;
    @{ $self->{_profiles} } = () if $self->{_profiles};
    $self->{_candles}  = undef;
}

sub add_manual_anchor {
    my ($self, $start_idx, $end_idx) = @_;
    push @{ $self->{_manual_anchors} }, { start => $start_idx, end => $end_idx };
}

sub clear_manual_anchors {
    my ($self) = @_;
    $self->{_manual_anchors} = [];
}

sub compute_all {
    my ($self, $market) = @_;
    $self->reset();

    my $arr = $market->_active_array();
    $self->{_candles} = $arr;
    my $n = scalar @$arr;
    return if $n < 2;

    my @segments = @{ $self->{_manual_anchors} // [] };

    # Calcular perfil para cada segmento
    my @profiles;
    for my $seg (@segments) {
        my $profile = $self->_compute_profile($arr, $seg->{start}, $seg->{end});
        next unless $profile;
        push @profiles, $profile;
    }

    @{ $self->{_profiles} } = @profiles;
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

    return undef if $price_max <= $price_min;
    my $range    = $price_max - $price_min;
    my $bin_size = $range / $num_bins;
    return undef if $bin_size <= 0;

    # Inicializar bins
    my @bins;
    for my $b (0 .. $num_bins - 1) {
        push @bins, {
            price_low  => $price_min + $b * $bin_size,
            price_high => $price_min + ($b + 1) * $bin_size,
            price      => $price_min + ($b + 0.5) * $bin_size,
            volume     => 0,
        };
    }

    # Distribuir volumen de cada vela proporcionalmente a sus bins
    my $total_vol = 0;
    for my $i ($start .. $end) {
        my $c = $arr->[$i];
        next unless defined $c->{high} && defined $c->{low} && defined $c->{volume};
        my $vol = $c->{volume};
        next if $vol <= 0;

        my $c_range = $c->{high} - $c->{low};
        $c_range = $bin_size * 0.01 if $c_range <= 0;   # vela doji

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
            $bins[$b]{volume} += $vol * $frac;
        }
        $total_vol += $vol;
    }

    return undef if $total_vol <= 0;

    # POC = bin con mayor volumen
    my $poc_bin = 0;
    for my $b (1 .. $#bins) {
        $poc_bin = $b if $bins[$b]{volume} > $bins[$poc_bin]{volume};
    }
    my $poc = $bins[$poc_bin]{price};

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

    return {
        start_idx => $start,
        end_idx   => $end,
        bins      => \@bins,
        poc       => $poc,
        poc_index => $poc_bin + $start,   # índice absoluto aproximado para VWAP anchor
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

1;
