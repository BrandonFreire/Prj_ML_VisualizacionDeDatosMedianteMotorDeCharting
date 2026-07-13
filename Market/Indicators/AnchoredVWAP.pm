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

        _manual_anchors    => [],
        _vwap_lines        => [],     # [{anchor_idx, values => [vwap_i], std_dev => [std_i]}]
        _candles           => undef,
        _smc_ref           => undef,
        _vp_ref            => undef,  # VolumeProfile indicator
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

sub reset {
    my ($self) = @_;
    @{ $self->{_vwap_lines} } = () if $self->{_vwap_lines};
    $self->{_candles}    = undef;
}

sub add_manual_anchor {
    my ($self, $idx) = @_;
    push @{ $self->{_manual_anchors} }, { index => $idx };
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

    # 1. Recopilar todos los anchors (ahora manuales)
    my @anchors = @{ $self->{_manual_anchors} // [] };

    # 2. Ordenar por índice y eliminar duplicados
    @anchors = sort { $a->{index} <=> $b->{index} } @anchors;
    my %seen;
    @anchors = grep { !$seen{$_->{index}}++ } @anchors;

    # 3. Calcular VWAP para cada anchor hasta el siguiente anchor o fin
    my @vwap_lines;
    for my $ai (0 .. $#anchors) {
        my $anchor = $anchors[$ai];
        my $start  = $anchor->{index};
        my $end    = $ai < $#anchors ? $anchors[$ai + 1]{index} - 1 : $n - 1;
        $end = $n - 1 if $end >= $n;
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
            values       => \@values,
            std_dev      => \@std_dev,
            mult_1       => $self->{std_mult_1},
            mult_2       => $self->{std_mult_2},
            mult_3       => $self->{std_mult_3},
        };
    }

    @{ $self->{_vwap_lines} } = @vwap_lines;
}



# ================================================================
# Accessors
# ================================================================
sub get_vwap_lines { return $_[0]->{_vwap_lines} }



1;
