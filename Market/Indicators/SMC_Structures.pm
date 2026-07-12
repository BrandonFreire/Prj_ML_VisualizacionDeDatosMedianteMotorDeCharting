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
        _ob          => [],   # Order Blocks [{index,direction,top,bottom,triggered_by,scope}]
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
    $self->{$_} = [] for qw(_sh _sl _bos _choch _fvg _ob _trendlines _major_highs _major_lows);
}

sub compute_all {
    my ($self, $market) = @_;
    $self->reset();

    my $arr = $market->_active_array();
    $self->{_candles} = $arr;
    my $n   = scalar @$arr;
    my $k   = $self->{depth};
    return if $n < 2 * $k + 2;
    my $external_k = _adaptive_external_depth(
        $n,
        $self->{external_depth} // ($k * 5),
        $k,
    );

    # ----------------------------------------------------------------
    # 1. Swing Highs y Swing Lows INTERNOS (depth k)
    # ----------------------------------------------------------------
    my (@sh_int, @sl_int);
    for my $i ( $k .. $n - $k - 1 ) {
        my ($is_sh, $is_sl) = (1, 1);
        for my $j (1 .. $k) {
            $is_sh = 0 if $arr->[$i]{high} <= $arr->[$i-$j]{high}
                       || $arr->[$i]{high} <= $arr->[$i+$j]{high};
            $is_sl = 0 if $arr->[$i]{low}  >= $arr->[$i-$j]{low}
                       || $arr->[$i]{low}  >= $arr->[$i+$j]{low};
        }
        push @sh_int, _make_pivot($i, $arr->[$i]{high}, $i + $k) if $is_sh;
        push @sl_int, _make_pivot($i, $arr->[$i]{low},  $i + $k) if $is_sl;
    }

    # ----------------------------------------------------------------
    # 2. Swing Highs y Swing Lows EXTERNOS (depth external_k) — independientes
    # ----------------------------------------------------------------
    my (@sh_ext, @sl_ext);
    if ( $n >= 2 * $external_k + 2 ) {
        for my $i ( $external_k .. $n - $external_k - 1 ) {
            my ($is_sh, $is_sl) = (1, 1);
            for my $j (1 .. $external_k) {
                $is_sh = 0 if $arr->[$i]{high} <= $arr->[$i-$j]{high}
                           || $arr->[$i]{high} <= $arr->[$i+$j]{high};
                $is_sl = 0 if $arr->[$i]{low}  >= $arr->[$i-$j]{low}
                           || $arr->[$i]{low}  >= $arr->[$i+$j]{low};
            }
            push @sh_ext, _make_pivot($i, $arr->[$i]{high}, $i + $external_k, $i + $external_k) if $is_sh;
            push @sl_ext, _make_pivot($i, $arr->[$i]{low},  $i + $external_k, $i + $external_k) if $is_sl;
        }
    }

    # Anotar pivotes internos que coincidan con pivotes externos
    my %ext_sh_idx = map { $_->{index} => $_ } @sh_ext;
    my %ext_sl_idx = map { $_->{index} => $_ } @sl_ext;
    for my $p (@sh_int) {
        if ( my $ep = $ext_sh_idx{ $p->{index} } ) {
            $p->{scope}              = 'external';
            $p->{scope_confirmed_at} = $ep->{confirmed_at};
        }
    }
    for my $p (@sl_int) {
        if ( my $ep = $ext_sl_idx{ $p->{index} } ) {
            $p->{scope}              = 'external';
            $p->{scope_confirmed_at} = $ep->{confirmed_at};
        }
    }

    $self->{_sh}          = \@sh_int;
    $self->{_sl}          = \@sl_int;
    $self->{_major_highs} = [ grep { ($_->{scope}//'internal') eq 'external' } @sh_int ];
    $self->{_major_lows}  = [ grep { ($_->{scope}//'internal') eq 'external' } @sl_int ];

    # ----------------------------------------------------------------
    # 3. BOS y CHoCH — DOS PASADAS INDEPENDIENTES
    #
    # Pasada interna : pivotes de depth k  → scope 'internal'
    # Pasada externa : pivotes de depth external_k → scope 'external'
    #
    # Cada pasada tiene su propio estado de tendencia y sus propios
    # flags swept, eliminando la contaminacion cruzada del enfoque
    # anterior de pasada unica.
    # ----------------------------------------------------------------
    my %sweep_at_index;
    if ( $self->{_lq_ref} ) {
        for my $ev ( @{ $self->{_lq_ref}->get_resolved() } ) {
            next unless ($ev->{classification}//'') eq 'SWEEP'
                     || ($ev->{classification}//'') eq 'GRAB';
            $sweep_at_index{ $ev->{resolved_at} // 0 } = $ev;
        }
    }

    my ($int_bos, $int_choch) = _detect_bos_choch($arr, \@sh_int, \@sl_int, 'internal', $k, \%sweep_at_index);
    my ($ext_bos, $ext_choch) = _detect_bos_choch($arr, \@sh_ext, \@sl_ext, 'external', $external_k, {});

    $self->{_bos}   = [ sort { $a->{index} <=> $b->{index} } (@$int_bos,   @$ext_bos)   ];
    $self->{_choch} = [ sort { $a->{index} <=> $b->{index} } (@$int_choch, @$ext_choch) ];

    # ----------------------------------------------------------------
    # 4. Order Blocks — ultima vela opuesta antes de cada BOS/CHoCH
    # ----------------------------------------------------------------
    {
        my @all_events = (@{ $self->{_bos} }, @{ $self->{_choch} });
        $self->{_ob} = _detect_order_blocks($arr, \@all_events);
    }

    # ----------------------------------------------------------------
    # 5. Trend Lines — conectan highs LH o lows HL consecutivos
    # ----------------------------------------------------------------
    $self->{_trendlines} = _detect_trendlines($arr, \@sh_int, \@sl_int);

    # ----------------------------------------------------------------
    # 6. Fair Value Gaps (FVG) — patron de 3 velas
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
                index       => $i,
                left_index  => $left,
                mid_index   => $i,
                formed_at   => $right,
                right_index => $right,
                direction   => 'bull',
                top         => $arr->[$right]{low},
                bottom      => $arr->[$left]{high},
            };
        }
        elsif ( $arr->[$right]{high} < $arr->[$left]{low} ) {
            push @{ $self->{_fvg} }, {
                index       => $i,
                left_index  => $left,
                mid_index   => $i,
                formed_at   => $right,
                right_index => $right,
                direction   => 'bear',
                top         => $arr->[$left]{low},
                bottom      => $arr->[$right]{high},
            };
        }
    }
}

# Crea un pivote con campos estandar
sub _make_pivot {
    my ($index, $price, $confirmed_at, $scope_confirmed_at) = @_;
    return {
        index              => $index,
        price              => $price,
        confirmed_at       => $confirmed_at,
        scope              => 'internal',
        scope_confirmed_at => $scope_confirmed_at // $confirmed_at,
        swept              => 0,
    };
}

# Detecta BOS y CHoCH en UNA sola coleccion de pivotes independiente.
# Cada llamada mantiene su propio estado de tendencia y flags swept.
sub _detect_bos_choch {
    my ($arr, $sh, $sl, $scope, $k, $sweep_lookup) = @_;
    $sweep_lookup //= {};
    my (@bos, @choch);
    my ($last_sh, $last_sl) = (undef, undef);
    my ($shi, $sli)         = (0, 0);
    my $n_sh  = scalar @$sh;
    my $n_sl  = scalar @$sl;
    my $trend = 0;
    my $n     = scalar @$arr;

    for my $i ( $k .. $n - 1 ) {
        while ($shi < $n_sh && ($sh->[$shi]{confirmed_at} // ($sh->[$shi]{index} + $k)) <= $i) {
            $last_sh = $sh->[$shi] unless $sh->[$shi]{swept};
            $shi++;
        }
        while ($sli < $n_sl && ($sl->[$sli]{confirmed_at} // ($sl->[$sli]{index} + $k)) <= $i) {
            $last_sl = $sl->[$sli] unless $sl->[$sli]{swept};
            $sli++;
        }

        # Ruptura alcista
        if ($last_sh && !$last_sh->{swept}
                && defined $arr->[$i]{close} && $arr->[$i]{close} > $last_sh->{price}) {
            $last_sh->{swept} = 1;
            my $is_choch = ($trend == -1);
            my $boosted  = $is_choch && _recent_sweep($sweep_lookup, $i, 'sl', 10);
            my $ev = {
                index              => $i,
                level              => $last_sh->{price},
                from               => $last_sh->{index},
                direction          => 'bull',
                scope              => $scope,
                confirmed_at       => $i,
                pivot_confirmed_at => $last_sh->{confirmed_at},
                scope_confirmed_at => $last_sh->{scope_confirmed_at} // $last_sh->{confirmed_at},
                boosted            => $boosted // 0,
            };
            push @{ $is_choch ? \@choch : \@bos }, $ev;
            $trend   = 1;
            $last_sh = undef;
        }

        # Ruptura bajista
        if ($last_sl && !$last_sl->{swept}
                && defined $arr->[$i]{close} && $arr->[$i]{close} < $last_sl->{price}) {
            $last_sl->{swept} = 1;
            my $is_choch = ($trend == 1);
            my $boosted  = $is_choch && _recent_sweep($sweep_lookup, $i, 'sh', 10);
            my $ev = {
                index              => $i,
                level              => $last_sl->{price},
                from               => $last_sl->{index},
                direction          => 'bear',
                scope              => $scope,
                confirmed_at       => $i,
                pivot_confirmed_at => $last_sl->{confirmed_at},
                scope_confirmed_at => $last_sl->{scope_confirmed_at} // $last_sl->{confirmed_at},
                boosted            => $boosted // 0,
            };
            push @{ $is_choch ? \@choch : \@bos }, $ev;
            $trend   = -1;
            $last_sl = undef;
        }
    }
    return (\@bos, \@choch);
}

sub get_swing_highs  { return $_[0]->{_sh}         }
sub get_swing_lows   { return $_[0]->{_sl}         }
sub get_bos_events   { return $_[0]->{_bos}        }
sub get_choch_events { return $_[0]->{_choch}      }
sub get_fvg_zones    { return $_[0]->{_fvg}        }
sub get_ob_zones     { return $_[0]->{_ob}         }
sub get_trendlines   { return $_[0]->{_trendlines} }
sub get_major_highs  { return $_[0]->{_major_highs} }
sub get_major_lows   { return $_[0]->{_major_lows}  }

sub _detect_order_blocks {
    my ($arr, $events) = @_;
    my @obs;
    my %seen;
    for my $ev (sort { ($a->{index}//0) <=> ($b->{index}//0) } @$events) {
        my $dir  = $ev->{direction} // '';
        my $from = $ev->{from};
        next unless defined $from && $from > 0;

        my $search_start = $from > 30 ? $from - 30 : 0;
        my $ob_idx;
        for my $i (reverse $search_start .. $from) {
            my $c = $arr->[$i] // next;
            next unless defined $c->{open} && defined $c->{close};
            if ($dir eq 'bull' && $c->{close} < $c->{open}) { $ob_idx = $i; last }
            if ($dir eq 'bear' && $c->{close} > $c->{open}) { $ob_idx = $i; last }
        }
        next unless defined $ob_idx;
        next if $seen{$ob_idx.$dir}++;

        my $c = $arr->[$ob_idx];
        my ($top, $bottom) = $dir eq 'bull'
            ? ($c->{open}, $c->{low})
            : ($c->{high}, $c->{open});

        push @obs, {
            index              => $ob_idx,
            direction          => $dir,
            top                => $top,
            bottom             => $bottom,
            triggered_by       => $ev->{index},
            scope              => $ev->{scope} // 'internal',
            confirmed_at       => $ev->{confirmed_at} // $ev->{index},
            scope_confirmed_at => $ev->{scope_confirmed_at} // $ev->{confirmed_at} // $ev->{index},
        };
    }
    return \@obs;
}

sub _detect_trendlines {
    my ($arr, $sh, $sl) = @_;
    my $n = scalar @$arr;
    my @tls;

    my @sh_ok = grep { defined $_->{index} && defined $_->{price} && defined $_->{confirmed_at} } @$sh;
    for my $i (1 .. $#sh_ok) {
        my ($p1, $p2) = ($sh_ok[$i-1], $sh_ok[$i]);
        next unless $p2->{price} < $p1->{price} && $p2->{index} > $p1->{index};
        my $span  = $p2->{index} - $p1->{index};
        my $slope = ($p2->{price} - $p1->{price}) / $span;
        my $break_at;
        for my $j ($p2->{confirmed_at} + 1 .. $n - 1) {
            my $lp = $p2->{price} + $slope * ($j - $p2->{index});
            if (defined $arr->[$j]{close} && $arr->[$j]{close} > $lp) {
                $break_at = $j; last;
            }
        }
        my $scope = ($p1->{scope}//'internal') eq 'external'
                 && ($p2->{scope}//'internal') eq 'external' ? 'external' : 'internal';
        push @tls, {
            from_index   => $p1->{index},
            from_price   => $p1->{price},
            to_index     => $p2->{index},
            to_price     => $p2->{price},
            direction    => 'bear',
            slope        => $slope,
            confirmed_at => $p2->{confirmed_at},
            break_at     => $break_at,
            scope        => $scope,
            scope_confirmed_at => $p2->{scope_confirmed_at} // $p2->{confirmed_at},
        };
    }

    my @sl_ok = grep { defined $_->{index} && defined $_->{price} && defined $_->{confirmed_at} } @$sl;
    for my $i (1 .. $#sl_ok) {
        my ($p1, $p2) = ($sl_ok[$i-1], $sl_ok[$i]);
        next unless $p2->{price} > $p1->{price} && $p2->{index} > $p1->{index};
        my $span  = $p2->{index} - $p1->{index};
        my $slope = ($p2->{price} - $p1->{price}) / $span;
        my $break_at;
        for my $j ($p2->{confirmed_at} + 1 .. $n - 1) {
            my $lp = $p2->{price} + $slope * ($j - $p2->{index});
            if (defined $arr->[$j]{close} && $arr->[$j]{close} < $lp) {
                $break_at = $j; last;
            }
        }
        my $scope = ($p1->{scope}//'internal') eq 'external'
                 && ($p2->{scope}//'internal') eq 'external' ? 'external' : 'internal';
        push @tls, {
            from_index   => $p1->{index},
            from_price   => $p1->{price},
            to_index     => $p2->{index},
            to_price     => $p2->{price},
            direction    => 'bull',
            slope        => $slope,
            confirmed_at => $p2->{confirmed_at},
            break_at     => $break_at,
            scope        => $scope,
            scope_confirmed_at => $p2->{scope_confirmed_at} // $p2->{confirmed_at},
        };
    }

    return \@tls;
}

sub _adaptive_external_depth {
    my ($n, $configured, $internal_k) = @_;
    $configured = defined $configured ? int($configured) : ($internal_k * 5);
    $configured = $internal_k + 2 if $configured <= $internal_k;

    my $cap = int($n / 8);
    $cap = $internal_k + 2 if $cap < $internal_k + 2;
    $cap = $configured if $cap > $configured;
    return $cap;
}

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
