package Market::Indicators::SMC_Structures;

use strict;
use warnings;

# Motor analitico de SMC: detecta Swing Points, BOS y Fair Value Gaps.
# Separacion estricta calculo / renderizado (ver Market::Overlays::SMC_Structures).

sub new {
    my ($class, %args) = @_;
    return bless {
        depth => $args{depth} // 3,   # k: barras de vecindad para swing points
        _sh   => [],   # swing highs: [{index, price, swept}]
        _sl   => [],   # swing lows:  [{index, price, swept}]
        _bos  => [],   # BOS events:  [{index, level, from, direction}]
        _fvg  => [],   # FVG zones:   [{index, top, bottom, direction}]
    }, $class;
}

sub reset {
    my ($self) = @_;
    $self->{$_} = [] for qw(_sh _sl _bos _fvg);
}

sub compute_all {
    my ($self, $market) = @_;
    $self->reset();

    my $arr = $market->_active_array();
    my $n   = scalar @$arr;
    my $k   = $self->{depth};
    return if $n < 2 * $k + 2;

    # ----------------------------------------------------------------
    # 1. Swing Highs y Swing Lows (condicion estricta de vecindad)
    #    High[i] > High[i-k..i-1] y High[i] > High[i+1..i+k]
    # ----------------------------------------------------------------
    my (@sh, @sl);
    for my $i ( $k .. $n - $k - 1 ) {
        my ($is_sh, $is_sl) = (1, 1);
        for my $j (1 .. $k) {
            $is_sh = 0 if $arr->[$i]{high} <= $arr->[$i-$j]{high}
                       || $arr->[$i]{high} <= $arr->[$i+$j]{high};
            $is_sl = 0 if $arr->[$i]{low}  >= $arr->[$i-$j]{low}
                       || $arr->[$i]{low}  >= $arr->[$i+$j]{low};
        }
        push @sh, { index => $i, price => $arr->[$i]{high}, swept => 0 } if $is_sh;
        push @sl, { index => $i, price => $arr->[$i]{low},  swept => 0 } if $is_sl;
    }
    $self->{_sh} = \@sh;
    $self->{_sl} = \@sl;

    # ----------------------------------------------------------------
    # 2. BOS (Break of Structure)
    #    Se registra cuando el cierre supera el ultimo swing no barrido.
    #    Algoritmo O(n): pointer al ultimo swing confirmado (i-k barras atras).
    # ----------------------------------------------------------------
    my ($last_sh, $last_sl) = (undef, undef);
    my ($shi, $sli) = (0, 0);   # punteros sobre @sh y @sl

    for my $i ( $k .. $n - 1 ) {
        # Avanzar punteros: usar solo swings cuya ventana ya cerro (index + k <= i)
        while ($shi < @sh && $sh[$shi]{index} + $k <= $i) {
            $last_sh = $sh[$shi] unless $sh[$shi]{swept};
            $shi++;
        }
        while ($sli < @sl && $sl[$sli]{index} + $k <= $i) {
            $last_sl = $sl[$sli] unless $sl[$sli]{swept};
            $sli++;
        }

        # BOS Alcista: cierre supera el ultimo swing high no barrido
        if ( $last_sh && !$last_sh->{swept} && $arr->[$i]{close} > $last_sh->{price} ) {
            $last_sh->{swept} = 1;
            push @{ $self->{_bos} }, {
                index     => $i,
                level     => $last_sh->{price},
                from      => $last_sh->{index},
                direction => 'bull',
            };
            $last_sh = undef;
        }

        # BOS Bajista: cierre perfora el ultimo swing low no barrido
        if ( $last_sl && !$last_sl->{swept} && $arr->[$i]{close} < $last_sl->{price} ) {
            $last_sl->{swept} = 1;
            push @{ $self->{_bos} }, {
                index     => $i,
                level     => $last_sl->{price},
                from      => $last_sl->{index},
                direction => 'bear',
            };
            $last_sl = undef;
        }
    }

    # ----------------------------------------------------------------
    # 3. Fair Value Gaps (FVG) — patron de 3 velas
    #    Bullish FVG:  Low[i+1] > High[i-1]  (hueco al alza)
    #    Bearish FVG:  High[i+1] < Low[i-1]  (hueco a la baja)
    # ----------------------------------------------------------------
    for my $i ( 1 .. $n - 2 ) {
        if ( $arr->[$i+1]{low} > $arr->[$i-1]{high} ) {
            push @{ $self->{_fvg} }, {
                index     => $i,
                direction => 'bull',
                top       => $arr->[$i+1]{low},
                bottom    => $arr->[$i-1]{high},
            };
        }
        elsif ( $arr->[$i+1]{high} < $arr->[$i-1]{low} ) {
            push @{ $self->{_fvg} }, {
                index     => $i,
                direction => 'bear',
                top       => $arr->[$i-1]{low},
                bottom    => $arr->[$i+1]{high},
            };
        }
    }
}

sub get_swing_highs { return $_[0]->{_sh}  }
sub get_swing_lows  { return $_[0]->{_sl}  }
sub get_bos_events  { return $_[0]->{_bos} }
sub get_fvg_zones   { return $_[0]->{_fvg} }

1;
