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
        _trailing_extremes => undef, # par Strong/Weak vigente
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
    $self->{_trailing_extremes} = undef;
}

sub compute_all {
    my ($self, $market) = @_;
    $self->reset();

    my $arr = $market->_active_array();
    $self->{_market} = $market;
    $self->{_candles} = $arr;
    my $n   = scalar @$arr;
    my $k   = $self->{depth};
    if ($n < 2 * $k + 2) {
        # Un FVG confirmado necesita tres velas, no una estructura de pivotes
        # completa. No se debe ocultar durante el warm-up de SMC.
        _detect_fvgs($arr, $self->{_fvg}, {});
        _annotate_fvg_lifecycle($arr, $self->{_fvg});
        return;
    }
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
        push @sh_int, _make_pivot($i, $arr->[$i]{high}, $i + $k,
            undef, 'high', $arr->[$i]{time}) if $is_sh;
        push @sl_int, _make_pivot($i, $arr->[$i]{low},  $i + $k,
            undef, 'low', $arr->[$i]{time}) if $is_sl;
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
            push @sh_ext, _make_pivot($i, $arr->[$i]{high}, $i + $external_k,
                $i + $external_k, 'high', $arr->[$i]{time}) if $is_sh;
            push @sl_ext, _make_pivot($i, $arr->[$i]{low},  $i + $external_k,
                $i + $external_k, 'low', $arr->[$i]{time}) if $is_sl;
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
    my %liquidity_at_index;
    if ( $self->{_lq_ref} ) {
        for my $ev ( @{ $self->{_lq_ref}->get_resolved() } ) {
            my $at = $ev->{resolved_at};
            next unless defined $at;
            push @{ $liquidity_at_index{$at} }, $ev;
        }
    }

    my ($int_bos, $int_choch) = _detect_bos_choch($arr, \@sh_int, \@sl_int, 'internal', $k, \%liquidity_at_index);
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

    # 6. Fair Value Gaps (FVG) — patrón de tres velas, independiente de que
    # ya haya pivotes suficientes para construir BOS/CHoCH.
    _detect_fvgs($arr, $self->{_fvg}, \%liquidity_at_index);

    _annotate_fvg_lifecycle($arr, $self->{_fvg});
    _annotate_order_block_lifecycle($arr, $self->{_ob});

    my @structure_events = (
        map { { %$_, type => 'BOS' } } @{ $self->{_bos} },
        map { { %$_, type => 'CHOCH' } } @{ $self->{_choch} },
    );
    $self->{_trailing_extremes} = _build_trailing_extremes(
        $arr, [ @sh_int, @sl_int ], \@structure_events, $n - 1,
    );
}

sub _detect_fvgs {
    my ($arr, $fvgs, $liquidity_lookup) = @_;
    return unless $arr && $fvgs;
    $liquidity_lookup //= {};
    my $n = scalar @$arr;
    return if $n < 3;

    # Bullish FVG: Low[i+1] > High[i-1].
    # Bearish FVG: High[i+1] < Low[i-1].
    for my $i (1 .. $n - 2) {
        my $left  = $i - 1;
        my $right = $i + 1;
        next unless defined $arr->[$left]{high}
                 && defined $arr->[$left]{low}
                 && defined $arr->[$right]{high}
                 && defined $arr->[$right]{low};

        if ($arr->[$right]{low} > $arr->[$left]{high}) {
            push @$fvgs, {
                index       => $i,
                left_index  => $left,
                mid_index   => $i,
                formed_at   => $right,
                right_index => $right,
                direction   => 'bull',
                top         => $arr->[$right]{low},
                bottom      => $arr->[$left]{high},
                high_reaction => _fvg_liquidity_reaction($liquidity_lookup, $right),
            };
        }
        elsif ($arr->[$right]{high} < $arr->[$left]{low}) {
            push @$fvgs, {
                index       => $i,
                left_index  => $left,
                mid_index   => $i,
                formed_at   => $right,
                right_index => $right,
                direction   => 'bear',
                top         => $arr->[$left]{low},
                bottom      => $arr->[$right]{high},
                high_reaction => _fvg_liquidity_reaction($liquidity_lookup, $right),
            };
        }
    }
}

# Crea un pivote con campos estandar
sub _make_pivot {
    my ($index, $price, $confirmed_at, $scope_confirmed_at, $kind, $time) = @_;
    return {
        id                 => join('_', 'smc', $kind // 'pivot', $index, $confirmed_at),
        kind               => $kind,
        index              => $index,
        time               => $time,
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
    my ($arr, $sh, $sl, $scope, $k, $liquidity_lookup) = @_;
    $liquidity_lookup //= {};
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
            my $signal = $is_choch
                ? _recent_liquidity_signal($liquidity_lookup, $i, 'sl', 'reversal', 10)
                : _recent_liquidity_signal($liquidity_lookup, $i, 'sh', 'continuation', 10);
            my $boosted  = $signal ? 1 : 0;
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
                probability_weight => $signal ? $signal->{probability_weight} : 0.50,
                liquidity_signal   => $signal ? $signal->{classification} : undef,
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
            my $signal = $is_choch
                ? _recent_liquidity_signal($liquidity_lookup, $i, 'sh', 'reversal', 10)
                : _recent_liquidity_signal($liquidity_lookup, $i, 'sl', 'continuation', 10);
            my $boosted  = $signal ? 1 : 0;
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
                probability_weight => $signal ? $signal->{probability_weight} : 0.50,
                liquidity_signal   => $signal ? $signal->{classification} : undef,
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
sub get_trailing_extremes { return $_[0]->{_trailing_extremes} }

# Calcula únicamente el par de extremos vigente. A diferencia de etiquetar
# cada pivote histórico, Strong/Weak es una propiedad del contexto estructural
# actual y por eso se reinicia con cada swing externo confirmado.
sub _build_trailing_extremes {
    my ($candles, $pivots, $structures, $max_idx) = @_;
    return undef unless $candles && @$candles && $pivots && @$pivots;
    $max_idx = $#$candles unless defined $max_idx;
    $max_idx = $#$candles if $max_idx > $#$candles;
    return undef if $max_idx < 0;

    my @external = sort {
        ($a->{confirmed_at} // 0) <=> ($b->{confirmed_at} // 0)
            || ($a->{index} // 0) <=> ($b->{index} // 0)
    } grep {
        ($_->{scope} // '') eq 'external'
            && ($_->{confirmed_at} // 9_999_999) < $max_idx
    } @$pivots;
    my ($swing_high, $swing_low);
    for my $pivot (@external) {
        $swing_high = $pivot if ($pivot->{kind} // $pivot->{type} // '') eq 'high';
        $swing_low  = $pivot if ($pivot->{kind} // $pivot->{type} // '') eq 'low';
    }
    return undef unless $swing_high && $swing_low;

    my ($top, $top_index, $top_time) = @{$swing_high}{qw(price index time)};
    my ($bottom, $bottom_index, $bottom_time) = @{$swing_low}{qw(price index time)};
    for my $i (($swing_high->{confirmed_at} // $swing_high->{index}) + 1 .. $max_idx) {
        next unless defined $candles->[$i]{high};
        if ($candles->[$i]{high} >= $top) {
            ($top, $top_index, $top_time) = ($candles->[$i]{high}, $i, $candles->[$i]{time});
        }
    }
    for my $i (($swing_low->{confirmed_at} // $swing_low->{index}) + 1 .. $max_idx) {
        next unless defined $candles->[$i]{low};
        if ($candles->[$i]{low} <= $bottom) {
            ($bottom, $bottom_index, $bottom_time) = ($candles->[$i]{low}, $i, $candles->[$i]{time});
        }
    }

    my ($bias, $bias_event, $bias_index) = ('neutral', undef, -1);
    for my $event (@{ $structures // [] }) {
        next unless ($event->{scope} // '') eq 'external';
        next unless ($event->{type} // '') =~ /^(?:BOS|CHOCH)$/;
        my $index = $event->{confirmation_index} // $event->{confirmed_at} // $event->{index};
        next unless defined $index && $index < $max_idx && $index >= $bias_index;
        my $direction = $event->{direction} // '';
        $direction = 'bullish' if $direction eq 'bull';
        $direction = 'bearish' if $direction eq 'bear';
        next unless $direction eq 'bullish' || $direction eq 'bearish';
        ($bias, $bias_event, $bias_index) = ($direction, $event, $index);
    }

    return {
        top => $top + 0, bottom => $bottom + 0,
        last_top_index => $top_index, last_top_time => $top_time,
        last_bottom_index => $bottom_index, last_bottom_time => $bottom_time,
        structural_bias => $bias,
        high_classification => $bias eq 'bearish' ? 'strong_high' : 'weak_high',
        low_classification  => $bias eq 'bullish' ? 'strong_low' : 'weak_low',
        source_high_pivot_id => $swing_high->{id} // join(':', 'high', $swing_high->{index}),
        source_low_pivot_id  => $swing_low->{id} // join(':', 'low', $swing_low->{index}),
        source_structure_event_id => $bias_event
            ? ($bias_event->{id} // join(':', $bias_event->{type}, $bias_index)) : undef,
        status => 'active', source_logic => 'smc_trailing_extremes', replay_safe => 1,
    };
}

# Resultado SMC reconstruido hasta un cursor de Replay. Los getters
# históricos siguen exponiendo el cálculo completo para el render normal;
# los consumidores analíticos pueden pedir este snapshot para no observar
# eventos, zonas u Order Blocks que todavía no existían en esa vela.
sub snapshot_at {
    my ($self, $last_index) = @_;
    my $market = $self->{_market} or return {
        swing_highs => [], swing_lows => [], bos => [], choch => [],
        fvgs => [], order_blocks => [], trendlines => [],
        major_highs => [], major_lows => [],
    };

    $last_index //= $market->last_index();
    my $prefix = $market->clone_upto($last_index);
    my $snapshot = ref($self)->new(
        depth          => $self->{depth},
        external_depth => $self->{external_depth},
    );
    $snapshot->set_liquidity_indicator($self->{_lq_ref}) if $self->{_lq_ref};
    $snapshot->compute_all($prefix);

    return {
        swing_highs => $snapshot->get_swing_highs(),
        swing_lows  => $snapshot->get_swing_lows(),
        bos         => $snapshot->get_bos_events(),
        choch       => $snapshot->get_choch_events(),
        fvgs        => $snapshot->get_fvg_zones(),
        order_blocks => $snapshot->get_ob_zones(),
        trendlines  => $snapshot->get_trendlines(),
        major_highs => $snapshot->get_major_highs(),
        major_lows  => $snapshot->get_major_lows(),
        trailing_extremes => $snapshot->get_trailing_extremes(),
    };
}

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

# El estado de FVG y Order Block pertenece al motor analítico. El overlay
# sigue decidiendo cómo dibujarlo, pero ya no necesita deducir si la zona fue
# mitigada usando datos propios. Las zonas históricas se conservan con su
# estado para auditoría y Replay.
sub _annotate_fvg_lifecycle {
    my ($arr, $fvgs) = @_;
    return unless $arr && $fvgs;

    for my $fvg (@$fvgs) {
        $fvg->{status}       = 'active';
        $fvg->{active}       = 1;
        $fvg->{fill_ratio}   = 0;
        $fvg->{mitigated_at} = undef;

        my $start = ($fvg->{formed_at} // -1) + 1;
        my $range = abs(($fvg->{top} // 0) - ($fvg->{bottom} // 0));
        next if $start > $#$arr || $range <= 0;

        for my $i ($start .. $#$arr) {
            my $c = $arr->[$i] // next;
            my $penetration;
            if (($fvg->{direction} // '') eq 'bull') {
                next unless defined $c->{low} && $c->{low} < $fvg->{top};
                $penetration = ($fvg->{top} - $c->{low}) / $range;
                $penetration = 1 if $c->{low} <= $fvg->{bottom};
            }
            else {
                next unless defined $c->{high} && $c->{high} > $fvg->{bottom};
                $penetration = ($c->{high} - $fvg->{bottom}) / $range;
                $penetration = 1 if $c->{high} >= $fvg->{top};
            }

            $penetration = 0 if $penetration < 0;
            $penetration = 1 if $penetration > 1;
            $fvg->{fill_ratio} = $penetration
                if $penetration > ($fvg->{fill_ratio} // 0);
            next unless $penetration >= 1;

            $fvg->{status}       = 'mitigated';
            $fvg->{active}       = 0;
            $fvg->{mitigated_at} = $i;
            last;
        }
    }
}

sub _annotate_order_block_lifecycle {
    my ($arr, $obs) = @_;
    return unless $arr && $obs;

    for my $ob (@$obs) {
        $ob->{status}    = 'active';
        $ob->{active}    = 1;
        $ob->{end_index} = undef;
        my $start = ($ob->{triggered_by} // $ob->{index} // -1) + 1;
        next if $start > $#$arr;

        for my $i ($start .. $#$arr) {
            my $c = $arr->[$i] // next;
            my $status;
            if (($ob->{direction} // '') eq 'bull') {
                next unless defined $c->{low} && $c->{low} <= $ob->{top};
                $status = $c->{low} <= $ob->{bottom} ? 'invalidated' : 'mitigated';
            }
            else {
                next unless defined $c->{high} && $c->{high} >= $ob->{bottom};
                $status = $c->{high} >= $ob->{top} ? 'invalidated' : 'mitigated';
            }
            $ob->{status}    = $status;
            $ob->{active}    = 0;
            $ob->{end_index} = $i;
            last;
        }
    }
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

# Convierte la resolución de liquidez en un peso explícito para SMC. Sweep
# eleva drásticamente CHoCH opuesto; Run valida BOS en la misma dirección.
sub _recent_liquidity_signal {
    my ($lookup, $bar_i, $side_filter, $intent, $window) = @_;
    my $best;
    for my $idx (keys %$lookup) {
        next if $idx > $bar_i || $idx < $bar_i - $window;
        for my $ev (@{ $lookup->{$idx} // [] }) {
            next unless ($ev->{side} // '') eq $side_filter;
            my $class = $ev->{classification} // '';
            next if $intent eq 'reversal'
                && $class ne 'SWEEP' && $class ne 'GRAB' && $class ne 'BIG_GRAB';
            next if $intent eq 'continuation' && $class ne 'RUN';
            my $base = $class eq 'SWEEP' ? 0.90
                     : $class eq 'BIG_GRAB' ? 0.88
                     : $class eq 'GRAB'  ? 0.82
                     :                    0.85; # RUN
            my $w = $ev->{volume_weight} // {};
            my $has_multi_tf_volume = (($w->{v1m}//0) + ($w->{v5m}//0) + ($w->{v15m}//0)) > 0;
            my $weight = $base + ($has_multi_tf_volume ? 0.05 : 0);
            $weight = 0.95 if $weight > 0.95;
            my $candidate = { %$ev, probability_weight => $weight };
            $best = $candidate if !$best || $candidate->{probability_weight} > $best->{probability_weight};
        }
    }
    return $best;
}

sub _fvg_liquidity_reaction {
    my ($lookup, $formed_at) = @_;
    for my $idx ($formed_at - 1 .. $formed_at) {
        for my $ev (@{ $lookup->{$idx} // [] }) {
            return 1 if ($ev->{classification} // '') eq 'SWEEP'
                     || ($ev->{classification} // '') eq 'GRAB'
                     || ($ev->{classification} // '') eq 'BIG_GRAB';
        }
    }
    return 0;
}

1;
