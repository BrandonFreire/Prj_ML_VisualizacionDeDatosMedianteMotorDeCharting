package Market::Indicators::Liquidity;

use strict;
use warnings;

# Motor de deteccion de liquidez con maquina de estados determinista.
#
# Ciclo de vida de cada nivel (especificacion Seccion 4.3):
#   [1 DETECTED]  nivel BSL/SSL o EQH/EQL identificado
#       |
#   [2 SWEPT]     High>BSL o Low<SSL (precio cruza el nivel)
#       |
#   +---+---+---+
#   |           |           |
# (N cierres  (cierre      (cierre
#  fuera)      rapido <=3)  tardio >3)
#   |           |           |
# [3 ACCEPTANCE] [4 RECLAIMED] [4 RECLAIMED]
#   |               |               |
# [5 RUN]        [5 GRAB]       [5 SWEEP]
#
# SWEEP: High>BSL + Close<BSL (regresa al rango previo, >3 velas)
# GRAB:  como sweep pero retorno en <=3 velas (rechazo rapido)
# RUN:   N=3 cierres consecutivos fuera del nivel (aceptacion institucional)

sub new {
    my ($class, %args) = @_;
    return bless {
        depth      => $args{depth}      // 3,   # k: vecindad swing points
        n_accept   => $args{n_accept}   // 3,   # velas consecutivas para RUN
        atr_period => $args{atr_period} // 14,  # para tolerancia EQH/EQL
        _levels    => [],
        _atr       => [],
    }, $class;
}

sub reset { my ($self) = @_; $self->{_levels} = []; $self->{_atr} = []; }

sub compute_all {
    my ($self, $market) = @_;
    $self->reset();

    my $arr = $market->_active_array();
    my $n   = scalar @$arr;
    my $k   = $self->{depth};
    return if $n < 2 * $k + 2;

    # ----------------------------------------------------------------
    # 1. ATR simple para tolerancia EQH/EQL (tolerancia = ATR * 0.10)
    # ----------------------------------------------------------------
    my @atr = _simple_atr($arr, $self->{atr_period});
    $self->{_atr} = \@atr;

    # ----------------------------------------------------------------
    # 2. Swing Highs (BSL) y Swing Lows (SSL)
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
        if ($is_sh) {
            push @sh, _make_level($i, $arr->[$i]{high}, 'BSL', 'sh');
        }
        if ($is_sl) {
            push @sl, _make_level($i, $arr->[$i]{low},  'SSL', 'sl');
        }
    }

    # ----------------------------------------------------------------
    # 3. EQH / EQL — dos pivotes con diferencia <= ATR*0.10
    # ----------------------------------------------------------------
    for my $a (0 .. $#sh) {
        for my $b ($a+1 .. $#sh) {
            my $tol = ($atr[$sh[$b]{index}] // 0) * 0.10;
            if ($tol > 0 && abs($sh[$a]{price} - $sh[$b]{price}) <= $tol) {
                $sh[$a]{is_eqh} = 1;
                $sh[$b]{is_eqh} = 1;
                $sh[$b]{eq_pair} = $sh[$a]{index};
            }
        }
    }
    for my $a (0 .. $#sl) {
        for my $b ($a+1 .. $#sl) {
            my $tol = ($atr[$sl[$b]{index}] // 0) * 0.10;
            if ($tol > 0 && abs($sl[$a]{price} - $sl[$b]{price}) <= $tol) {
                $sl[$a]{is_eql} = 1;
                $sl[$b]{is_eql} = 1;
                $sl[$b]{eq_pair} = $sl[$a]{index};
            }
        }
    }

    # ----------------------------------------------------------------
    # 4. Maquina de estados — procesar cada nivel barra a barra
    # ----------------------------------------------------------------
    my @all = sort { $a->{index} <=> $b->{index} } (@sh, @sl);

    for my $lvl (@all) {
        _run_state_machine($lvl, $arr, $n, $self->{n_accept});
    }

    $self->{_levels} = \@all;
}

# ----------------------------------------------------------------
# Maquina de estados determinista para un nivel
# ----------------------------------------------------------------
sub _run_state_machine {
    my ($lvl, $arr, $n, $n_accept) = @_;
    my $det_i = $lvl->{index};
    my $price = $lvl->{price};
    my $side  = $lvl->{side};

    # Estado 2: SWEPT — buscar primera barra que cruce el nivel
    my $swept_i = undef;
    for my $i ($det_i + 1 .. $n - 1) {
        if ($side eq 'sh' && $arr->[$i]{high} > $price) { $swept_i = $i; last }
        if ($side eq 'sl' && $arr->[$i]{low}  < $price) { $swept_i = $i; last }
    }

    unless (defined $swept_i) {
        # Nivel activo no barrido — queda en DETECTED
        return;
    }

    $lvl->{state}    = 'SWEPT';
    $lvl->{swept_at} = $swept_i;

    # Estados 3/4: ACCEPTANCE vs RECLAIMED
    my $consec_out = 0;
    my $max_look   = _min($swept_i + 30, $n - 1);

    for my $i ($swept_i .. $max_look) {
        my $close_out = ($side eq 'sh')
            ? $arr->[$i]{close} > $price
            : $arr->[$i]{close} < $price;

        if ($close_out) {
            $consec_out++;
            if ($consec_out >= $n_accept) {
                # Estado 3: ACCEPTANCE → RUN
                $lvl->{state}          = 'ACCEPTANCE';
                $lvl->{resolved_at}    = $i;
                $lvl->{classification} = 'RUN';
                $lvl->{state}          = 'RESOLVED';
                return;
            }
        } else {
            # Cierre dentro del rango: RECLAIMED
            my $bars_out = $i - $swept_i;
            my $class = ($bars_out <= 3) ? 'GRAB' : 'SWEEP';
            $lvl->{state}          = 'RECLAIMED';
            $lvl->{resolved_at}    = $i;
            $lvl->{classification} = $class;
            $lvl->{state}          = 'RESOLVED';
            return;
        }
    }

    # Si llego al limite sin resolver: clasificar como SWEEP provisional
    $lvl->{state}          = 'RESOLVED';
    $lvl->{resolved_at}    = $max_look;
    $lvl->{classification} = 'SWEEP';
}

# ----------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------
sub _make_level {
    my ($index, $price, $type, $side) = @_;
    return {
        index          => $index,
        price          => $price,
        type           => $type,   # BSL | SSL
        side           => $side,   # sh  | sl
        is_eqh         => 0,
        is_eql         => 0,
        state          => 'DETECTED',
        swept_at       => undef,
        resolved_at    => undef,
        classification => undef,   # SWEEP | GRAB | RUN (cuando RESOLVED)
    };
}

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
    }
    return @atr;
}

sub _min { $_[0] < $_[1] ? $_[0] : $_[1] }

# ----------------------------------------------------------------
# Accessors
# ----------------------------------------------------------------
sub get_levels     { return $_[0]->{_levels} }
sub get_atr        { return $_[0]->{_atr}    }

# Niveles activos (aun no barridos) por tipo
sub get_bsl_levels {
    return [ grep { $_->{side} eq 'sh' && $_->{state} eq 'DETECTED' }
             @{ $_[0]->{_levels} } ];
}
sub get_ssl_levels {
    return [ grep { $_->{side} eq 'sl' && $_->{state} eq 'DETECTED' }
             @{ $_[0]->{_levels} } ];
}

sub get_active {
    return [ grep { $_->{state} eq 'DETECTED' || $_->{state} eq 'SWEPT' }
             @{ $_[0]->{_levels} } ];
}
sub get_resolved {
    return [ grep { defined $_->{classification} } @{ $_[0]->{_levels} } ];
}
sub get_by_class {
    my ($self, $class) = @_;
    return [ grep { ($_->{classification}//'') eq $class } @{ $self->{_levels} } ];
}
sub get_eqh {
    return [ grep { $_->{is_eqh} } @{ $_[0]->{_levels} } ];
}
sub get_eql {
    return [ grep { $_->{is_eql} } @{ $_[0]->{_levels} } ];
}

1;
