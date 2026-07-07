package Market::Indicators::SMC_Structures;

use strict;
use warnings;

# Motor analitico de SMC: detecta Swing Points, BOS y Fair Value Gaps.
# Separacion estricta calculo / renderizado (ver Market::Overlays::SMC_Structures).

sub new {
    my ($class, %args) = @_;
    return bless {
        depth        => $args{depth} // 3,
        external_depth => $args{external_depth},
        _sh          => [],   # swing highs
        _sl          => [],   # swing lows
        _bos         => [],   # BOS events  [{index,level,from,direction}]
        _choch       => [],   # CHoCH events [{index,level,from,direction}]
        _fvg         => [],   # FVG zones
        _major_highs => [],   # external swing highs used as major structure
        _major_lows  => [],   # external swing lows used as major structure
        _candles     => undef, # referencia al arreglo activo para mitigacion visual de FVG
        _lq_ref      => undef, # referencia opcional al indicador Liquidity
    }, $class;
}

# Permite vincular el indicador Liquidity para ajustar probabilidades BOS/CHoCH
sub set_liquidity_indicator {
    my ($self, $lq) = @_;
    $self->{_lq_ref} = $lq;
}

sub reset {
    my ($self) = @_;
    $self->{$_} = [] for qw(_sh _sl _bos _choch _fvg _major_highs _major_lows);
}

sub compute_all {
    my ($self, $market) = @_;
    $self->reset();

    my $arr = $market->_active_array();
    $self->{_candles} = $arr;
    my $n   = scalar @$arr;
    my $k   = $self->{depth};
    return if $n < 2 * $k + 2;
    my $external_k = $self->{external_depth} // ($k * 3);
    $external_k = $k + 2 if $external_k <= $k;

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
        push @sh, {
            index        => $i,
            price        => $arr->[$i]{high},
            swept        => 0,
            confirmed_at => $i + $k,
        } if $is_sh;
        push @sl, {
            index        => $i,
            price        => $arr->[$i]{low},
            swept        => 0,
            confirmed_at => $i + $k,
        } if $is_sl;
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
    for my $s (@sh) {
        if ( defined $external_sh{ $s->{index} } ) {
            $s->{scope} = 'external';
            $s->{scope_confirmed_at} = $external_sh{ $s->{index} };
        } else {
            $s->{scope} = 'internal';
            $s->{scope_confirmed_at} = $s->{confirmed_at};
        }
    }
    for my $s (@sl) {
        if ( defined $external_sl{ $s->{index} } ) {
            $s->{scope} = 'external';
            $s->{scope_confirmed_at} = $external_sl{ $s->{index} };
        } else {
            $s->{scope} = 'internal';
            $s->{scope_confirmed_at} = $s->{confirmed_at};
        }
    }
    $self->{_sh} = \@sh;
    $self->{_sl} = \@sl;
    $self->{_major_highs} = [ grep { ($_->{scope}//'internal') eq 'external' } @sh ];
    $self->{_major_lows}  = [ grep { ($_->{scope}//'internal') eq 'external' } @sl ];

    # ----------------------------------------------------------------
    # 2. BOS y CHoCH con vinculacion a vectores de liquidez
    #
    # BOS  = ruptura en la MISMA direccion que la tendencia actual
    # CHoCH = ruptura en direccion CONTRARIA (cambio de caracter)
    #
    # Segun especificacion: si ocurrio un SWEEP de liquidez reciente,
    # se incrementa la probabilidad de CHoCH en la direccion opuesta.
    # Implementamos esto marcando choch_boosted=1 cuando hay un SWEEP
    # previo que coincide con la direccion del CHoCH detectado.
    # ----------------------------------------------------------------
    my ($last_sh, $last_sl)   = (undef, undef);
    my ($shi, $sli)           = (0, 0);
    my $trend = 0;   # 0=neutral, 1=bullish, -1=bearish

    # Construir lookup de SWEEP events del indicador Liquidity (si esta vinculado)
    my %sweep_at_index;
    if ( $self->{_lq_ref} ) {
        for my $ev ( @{ $self->{_lq_ref}->get_resolved() } ) {
            next unless ($ev->{classification}//'') eq 'SWEEP'
                     || ($ev->{classification}//'') eq 'GRAB';
            $sweep_at_index{ $ev->{resolved_at} // 0 } = $ev;
        }
    }

    for my $i ( $k .. $n - 1 ) {
        while ($shi < @sh && ($sh[$shi]{confirmed_at} // ($sh[$shi]{index} + $k)) <= $i) {
            $last_sh = $sh[$shi] unless $sh[$shi]{swept};
            $shi++;
        }
        while ($sli < @sl && ($sl[$sli]{confirmed_at} // ($sl[$sli]{index} + $k)) <= $i) {
            $last_sl = $sl[$sli] unless $sl[$sli]{swept};
            $sli++;
        }

        # Ruptura alcista (cierre > ultimo swing high)
        if ( $last_sh && !$last_sh->{swept} && $arr->[$i]{close} > $last_sh->{price} ) {
            $last_sh->{swept} = 1;
            my $is_choch = ($trend == -1);   # tendencia bajista previa → cambio de caracter
            my $boosted  = $is_choch && _recent_sweep(\%sweep_at_index, $i, 'sl', 10);
            my $event = {
                index     => $i,
                level     => $last_sh->{price},
                from      => $last_sh->{index},
                direction => 'bull',
                scope     => $last_sh->{scope} // 'internal',
                confirmed_at => $i,
                pivot_confirmed_at => $last_sh->{confirmed_at},
                scope_confirmed_at => $last_sh->{scope_confirmed_at} // $last_sh->{confirmed_at},
                boosted   => $boosted // 0,
            };
            if ($is_choch) { push @{ $self->{_choch} }, $event }
            else           { push @{ $self->{_bos}   }, $event }
            $trend   = 1;
            $last_sh = undef;
        }

        # Ruptura bajista (cierre < ultimo swing low)
        if ( $last_sl && !$last_sl->{swept} && $arr->[$i]{close} < $last_sl->{price} ) {
            $last_sl->{swept} = 1;
            my $is_choch = ($trend == 1);    # tendencia alcista previa → cambio de caracter
            my $boosted  = $is_choch && _recent_sweep(\%sweep_at_index, $i, 'sh', 10);
            my $event = {
                index     => $i,
                level     => $last_sl->{price},
                from      => $last_sl->{index},
                direction => 'bear',
                scope     => $last_sl->{scope} // 'internal',
                confirmed_at => $i,
                pivot_confirmed_at => $last_sl->{confirmed_at},
                scope_confirmed_at => $last_sl->{scope_confirmed_at} // $last_sl->{confirmed_at},
                boosted   => $boosted // 0,
            };
            if ($is_choch) { push @{ $self->{_choch} }, $event }
            else           { push @{ $self->{_bos}   }, $event }
            $trend   = -1;
            $last_sl = undef;
        }
    }

    # ----------------------------------------------------------------
    # 3. Fair Value Gaps (FVG) — patron de 3 velas
    #    Bullish FVG:  Low[i+1] > High[i-1]  (hueco al alza)
    #    Bearish FVG:  High[i+1] < Low[i-1]  (hueco a la baja)
    # ----------------------------------------------------------------
    for my $i ( 1 .. $n - 2 ) {
        my $left  = $i - 1;
        my $right = $i + 1;
        next unless defined $arr->[$left]{high}
                 && defined $arr->[$left]{low}
                 && defined $arr->[$right]{high}
                 && defined $arr->[$right]{low};

        if ( $arr->[$right]{low} > $arr->[$left]{high} ) {
            push @{ $self->{_fvg} }, {
                index     => $i,
                left_index => $left,
                mid_index  => $i,
                formed_at  => $right,
                right_index => $right,
                direction => 'bull',
                top       => $arr->[$right]{low},
                bottom    => $arr->[$left]{high},
            };
        }
        elsif ( $arr->[$right]{high} < $arr->[$left]{low} ) {
            push @{ $self->{_fvg} }, {
                index     => $i,
                left_index => $left,
                mid_index  => $i,
                formed_at  => $right,
                right_index => $right,
                direction => 'bear',
                top       => $arr->[$left]{low},
                bottom    => $arr->[$right]{high},
            };
        }
    }
}

sub get_swing_highs  { return $_[0]->{_sh}    }
sub get_swing_lows   { return $_[0]->{_sl}    }
sub get_bos_events   { return $_[0]->{_bos}   }
sub get_choch_events { return $_[0]->{_choch} }
sub get_fvg_zones    { return $_[0]->{_fvg}   }
sub get_major_highs  { return $_[0]->{_major_highs} }
sub get_major_lows   { return $_[0]->{_major_lows}  }

# Devuelve true si hay un evento SWEEP/GRAB en el indicador Liquidity
# dentro de las ultimas $window barras antes de $bar_i, del tipo $side (sh/sl).
sub _recent_sweep {
    my ($lookup, $bar_i, $side_filter, $window) = @_;
    for my $idx (keys %$lookup) {
        next if $idx > $bar_i || $idx < $bar_i - $window;
        my $ev = $lookup->{$idx};
        return 1 if ($ev->{side}//'') eq $side_filter;
    }
    return 0;
}

1;
