package Market::Overlays::SMC_Structures;

use strict;
use warnings;

# Renderizado grafico de las estructuras SMC: BOS y FVG.
# No hace calculos — lee del indicador Market::Indicators::SMC_Structures.
# Cumple la separacion Calculo / Renderizado de la Tabla 1 de la especificacion.

my $COLOR_BOS_BULL   = '#26a69a';
my $COLOR_BOS_BEAR   = '#ef5350';
my $COLOR_CHOCH_BULL = '#64b5f6';
my $COLOR_CHOCH_BEAR = '#ff9800';
my $COLOR_FVG_BULL   = '#26a69a';
my $COLOR_FVG_BEAR   = '#ef5350';
my $COLOR_ZONE_HIGH  = '#f6c90e';
my $COLOR_OB_BULL    = '#26a69a';
my $COLOR_OB_BEAR    = '#ef5350';
my $COLOR_TL_BULL    = '#26a69a';
my $COLOR_TL_BEAR    = '#ef5350';

sub new {
    my ($class, %args) = @_;
    return bless {
        indicator      => $args{indicator},
        visibility     => $args{visibility},
        show_bos       => $args{show_bos} // 1,
        show_fvg       => $args{show_fvg} // 1,
        fvg_max_age    => exists $args{fvg_max_age} ? $args{fvg_max_age} : 120,
        fvg_mitigation => $args{fvg_mitigation} // 'full',
        max_structure_events => $args{max_structure_events} // 80,
        max_fvg_visible      => $args{max_fvg_visible} // 45,
        max_swing_labels     => $args{max_swing_labels} // 90,
        fvg_reaction_window  => $args{fvg_reaction_window} // 12,
    }, $class;
}

sub set_visibility {
    my ($self, $visibility) = @_;
    $self->{visibility} = $visibility;
}

sub _visible {
    my ($self, $key, $default) = @_;
    my $v = $self->{visibility};
    return $default unless $v && exists $v->{$key};
    return $v->{$key} ? 1 : 0;
}

# Renderiza BOS y FVG sobre el canvas de precio.
# $current_bar = d_end (ultima barra visible, barrera en modo Replay)
sub render {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    $current_bar //= $d_end;
    my $ind = $self->{indicator};
    return unless $ind;

    $canvas->delete('smc_overlay');
    $self->{_label_slots} = {};
    return unless $self->_visible('smc_enabled', 1);

    # Construir lookup de sweeps recientes para marcar FVGs como Zona de Alta Reaccion
    my %recent_sweeps;
    if ( $self->{indicator}->can('get_choch_events') ) {
        my $lq_ref = $self->{indicator}{_lq_ref};
        if ($lq_ref) {
            for my $ev ( @{ $lq_ref->get_resolved() } ) {
                next unless ($ev->{classification}//'') eq 'SWEEP'
                         || ($ev->{classification}//'') eq 'GRAB';
                my $ri = $ev->{resolved_at} // next;
                my $side = $ev->{side} // '';
                $recent_sweeps{$ri}{$side} = 1 if $side ne '';
            }
        }
    }

    $self->_render_premium_discount( $canvas, $d_start, $d_end, $scale, $current_bar )
        if $self->_visible('show_premium_discount', 1);
    $self->_render_trendlines( $canvas, $d_start, $d_end, $scale, $current_bar )
        if $self->_visible('show_trendlines', 1);
    $self->_render_order_blocks( $canvas, $d_start, $d_end, $scale, $current_bar )
        if $self->_visible('show_ob', 1);
    $self->_render_swing_labels( $canvas, $d_start, $d_end, $scale, $current_bar );
    $self->_render_major_levels( $canvas, $d_start, $d_end, $scale, $current_bar )
        if $self->_visible('show_major_levels', 1);
    $self->_render_fvg( $canvas, $d_start, $d_end, $scale, $current_bar, \%recent_sweeps )
        if $self->{show_fvg} && $self->_visible('show_fvg', 1);
    $self->_render_bos( $canvas, $d_start, $d_end, $scale, $current_bar )
        if $self->{show_bos} && $self->_visible('show_bos', 1);
    $self->_render_choch( $canvas, $d_start, $d_end, $scale, $current_bar )
        if $self->_visible('show_choch', 1);
    $self->_render_fibonacci( $canvas, $d_start, $d_end, $scale, $current_bar )
        if $self->_visible('show_fibonacci_auto', $self->_visible('show_fibonacci', 0));
    $self->_render_market_regime( $canvas, $current_bar )
        if $self->_visible('show_market_regime', 0);
}

# ----------------------------------------------------------------
# FVG — rectángulos con desvanecimiento progresivo usando stipple
# ----------------------------------------------------------------
sub _render_swing_labels {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    return unless $self->{indicator}->can('get_swing_highs')
               && $self->{indicator}->can('get_swing_lows');

    my $show_hh = $self->_visible('show_hh', 0);
    my $show_hl = $self->_visible('show_hl', 0);
    my $show_lh = $self->_visible('show_lh', 0);
    my $show_ll = $self->_visible('show_ll', 0);
    my $show_sh = $self->_visible('show_sh', 0);
    my $show_sl = $self->_visible('show_sl', 0);
    return unless $show_hh || $show_hl || $show_lh || $show_ll || $show_sh || $show_sl;

    my $labels_drawn = 0;
    my $max_labels = int( $self->{max_swing_labels} // 90 );

    my $last_high;
    for my $sh ( @{ $self->{indicator}->get_swing_highs() // [] } ) {
        last if $max_labels > 0 && $labels_drawn >= $max_labels;
        my $idx = $sh->{index};
        my $price = $sh->{price};
        next unless defined $idx && defined $price;
        next if $idx > $current_bar;
        my $confirmed_at = $sh->{confirmed_at} // $idx;
        next if defined $confirmed_at && $confirmed_at > $current_bar;
        next unless $self->_show_structure_scope($sh, $current_bar);

        my $label = defined $last_high && $price > $last_high ? 'HH' : 'LH';
        $last_high = $price;
        next if $idx < $d_start || $idx > $d_end;
        my $x = $scale->index_to_center_x($idx);
        my $y = $scale->value_to_y($price);
        my $scope_color = $self->_effective_scope($sh, $current_bar) eq 'external'
            ? '#f6c90e' : '#b2b5be';

        if ((($label eq 'HH' && $show_hh) || ($label eq 'LH' && $show_lh))
            && $self->_claim_label_slot( $x, $y - 10 )) {
            $canvas->createText( $x, $y - 10,
                -text => $label, -fill => '#b2b5be',
                -font => ['Helvetica', 7, 'bold'], -anchor => 'center',
                -tags => ['smc_overlay', 'smc_label', lc($label)],
            );
            $labels_drawn++;
        }
        if ($show_sh && $self->_claim_label_slot( $x, $y - 22 )) {
            $canvas->createText( $x, $y - 22,
                -text => 'SH', -fill => $scope_color,
                -font => ['Helvetica', 7, 'bold'], -anchor => 'center',
                -tags => ['smc_overlay', 'smc_label', 'sh'],
            );
            $labels_drawn++;
        }
    }

    my $last_low;
    for my $sl ( @{ $self->{indicator}->get_swing_lows() // [] } ) {
        last if $max_labels > 0 && $labels_drawn >= $max_labels;
        my $idx = $sl->{index};
        my $price = $sl->{price};
        next unless defined $idx && defined $price;
        next if $idx > $current_bar;
        my $confirmed_at = $sl->{confirmed_at} // $idx;
        next if defined $confirmed_at && $confirmed_at > $current_bar;
        next unless $self->_show_structure_scope($sl, $current_bar);

        my $label = defined $last_low && $price > $last_low ? 'HL' : 'LL';
        $last_low = $price;
        next if $idx < $d_start || $idx > $d_end;
        my $x = $scale->index_to_center_x($idx);
        my $y = $scale->value_to_y($price);
        my $scope_color = $self->_effective_scope($sl, $current_bar) eq 'external'
            ? '#f6c90e' : '#b2b5be';

        if ((($label eq 'HL' && $show_hl) || ($label eq 'LL' && $show_ll))
            && $self->_claim_label_slot( $x, $y + 10 )) {
            $canvas->createText( $x, $y + 10,
                -text => $label, -fill => '#b2b5be',
                -font => ['Helvetica', 7, 'bold'], -anchor => 'center',
                -tags => ['smc_overlay', 'smc_label', lc($label)],
            );
            $labels_drawn++;
        }
        if ($show_sl && $self->_claim_label_slot( $x, $y + 22 )) {
            $canvas->createText( $x, $y + 22,
                -text => 'SL', -fill => $scope_color,
                -font => ['Helvetica', 7, 'bold'], -anchor => 'center',
                -tags => ['smc_overlay', 'smc_label', 'sl'],
            );
            $labels_drawn++;
        }
    }
}

sub _render_major_levels {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    return unless $self->_visible('show_external_structure', 1);
    return unless $self->{indicator}->can('get_major_highs')
               && $self->{indicator}->can('get_major_lows');

    my $mh = $self->_latest_confirmed_major(
        $self->{indicator}->get_major_highs() // [], $current_bar
    );
    my $ml = $self->_latest_confirmed_major(
        $self->{indicator}->get_major_lows() // [], $current_bar
    );

    $self->_draw_major_level(
        $canvas, $d_start, $d_end, $scale, $current_bar,
        $mh, 'Major High', '#f6c90e', -12
    ) if $mh;
    $self->_draw_major_level(
        $canvas, $d_start, $d_end, $scale, $current_bar,
        $ml, 'Major Low', '#f6c90e', 12
    ) if $ml;
}

sub _render_premium_discount {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    return unless $self->_visible('show_external_structure', 1);
    return unless $self->{indicator}->can('get_major_highs')
               && $self->{indicator}->can('get_major_lows');

    my $mh = $self->_latest_confirmed_major(
        $self->{indicator}->get_major_highs() // [], $current_bar
    );
    my $ml = $self->_latest_confirmed_major(
        $self->{indicator}->get_major_lows() // [], $current_bar
    );
    return unless $mh && $ml;
    return unless defined $mh->{price} && defined $ml->{price};

    my $high = $mh->{price} > $ml->{price} ? $mh->{price} : $ml->{price};
    my $low  = $mh->{price} > $ml->{price} ? $ml->{price} : $mh->{price};
    return if abs($high - $low) < 0.000001;

    my $start = ($mh->{index} // 0) < ($ml->{index} // 0) ? ($mh->{index} // 0) : ($ml->{index} // 0);
    my $end   = $current_bar < $d_end ? $current_bar : $d_end;
    return if $start > $end || $end < $d_start || $start > $d_end;

    my $draw_start = $start < $d_start ? $d_start : $start;
    my $draw_end   = $end   > $d_end   ? $d_end   : $end;
    return if $draw_start > $draw_end;

    my $x1 = $scale->index_to_center_x($draw_start);
    my $x2 = $scale->index_to_center_x($draw_end);
    return if $x1 > $scale->{x_width} || $x2 < 0 || $x1 >= $x2;

    my $eq = ($high + $low) / 2;
    my $y_high = $scale->value_to_y($high);
    my $y_eq   = $scale->value_to_y($eq);
    my $y_low  = $scale->value_to_y($low);
    my $h = $scale->{y_height} || 1;

    $y_high = 0 if $y_high < 0;
    $y_low  = $h if $y_low > $h;
    return if $y_eq < 0 || $y_eq > $h;

    $canvas->createRectangle( $x1, $y_high, $x2, $y_eq,
        -fill => '#5f3b3b', -outline => '',
        -stipple => 'gray12',
        -tags => ['smc_overlay', 'premium_discount'],
    );
    $canvas->createRectangle( $x1, $y_eq, $x2, $y_low,
        -fill => '#2f5047', -outline => '',
        -stipple => 'gray12',
        -tags => ['smc_overlay', 'premium_discount'],
    );
    $canvas->createLine( $x1, $y_eq, $x2, $y_eq,
        -fill => '#9aa5b5', -width => 1, -dash => [3, 4],
        -tags => ['smc_overlay', 'premium_discount'],
    );

    if ( $self->_claim_label_slot( $x2 - 8, $y_eq - 8 ) ) {
        $canvas->createText( $x2 - 8, $y_eq - 8,
            -text => 'EQ 50%',
            -fill => '#9aa5b5',
            -font => ['Helvetica', 7, 'bold'],
            -anchor => 'e',
            -tags => ['smc_overlay', 'smc_label', 'premium_discount'],
        );
    }
}

sub _latest_confirmed_major {
    my ($self, $items, $current_bar) = @_;
    my @ready = grep {
        defined $_->{index}
            && defined $_->{price}
            && ($_->{index} // 0) <= $current_bar
            && (($_->{scope_confirmed_at} // $_->{confirmed_at} // $_->{index}) <= $current_bar)
    } @$items;
    return unless @ready;
    my ($latest) = sort {
        ($b->{index} // 0) <=> ($a->{index} // 0)
    } @ready;
    return $latest;
}

sub _draw_major_level {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $item, $label, $color, $yoff) = @_;
    return unless $item && defined $item->{index} && defined $item->{price};

    my $start = $item->{index};
    my $end   = $current_bar < $d_end ? $current_bar : $d_end;
    return if $start > $end || $end < $d_start || $start > $d_end;

    my $draw_start = $start < $d_start ? $d_start : $start;
    my $draw_end   = $end   > $d_end   ? $d_end   : $end;
    return if $draw_start > $draw_end;

    my $y = $scale->value_to_y($item->{price});
    return if defined $scale->{y_height} && ($y < -20 || $y > $scale->{y_height} + 20);

    my $x1 = $scale->index_to_center_x($draw_start);
    my $x2 = $scale->index_to_center_x($draw_end);
    return if $x1 > $scale->{x_width} || $x2 < 0 || $x1 > $x2;

    $canvas->createLine( $x1, $y, $x2, $y,
        -fill => $color, -width => 1.8, -dash => [8, 3],
        -tags => ['smc_overlay', 'major_level'],
    );

    return unless $self->_claim_label_slot( $x2 - 8, $y + $yoff );
    $canvas->createText( $x2 - 8, $y + $yoff,
        -text => $label, -fill => $color,
        -font => ['Helvetica', 8, 'bold'],
        -anchor => 'e',
        -tags => ['smc_overlay', 'smc_label', 'major_level'],
    );
}

sub _render_fibonacci {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;

    my @events;
    push @events, @{ $self->{indicator}->get_bos_events() // [] }
        if $self->{indicator}->can('get_bos_events');
    push @events, @{ $self->{indicator}->get_choch_events() // [] }
        if $self->{indicator}->can('get_choch_events');

    @events = grep {
        defined $_->{index} && defined $_->{from} && defined $_->{level}
            && $self->_event_visible_at($_, $current_bar)
    } @events;
    return unless @events;

    my ($ev) = sort { $b->{index} <=> $a->{index} } @events;
    my $from = $ev->{from};
    my $to   = $ev->{index};
    return if $to < $d_start || $from > $d_end;

    my $candles = $self->{indicator}{_candles} // [];
    my $c = $candles->[$to];
    return unless $c;

    my $p0 = $ev->{level};
    my $p1 = $c->{close};
    if (abs($p1 - $p0) < 0.000001) {
        $p1 = ($ev->{direction}//'') eq 'bull' ? $c->{high} : $c->{low};
    }
    return if abs($p1 - $p0) < 0.000001;

    my $draw_start = $from < $d_start ? $d_start : $from;
    my $draw_end   = $to   > $d_end   ? $d_end   : $to;
    return if $draw_start > $draw_end;

    my $x1 = $scale->index_to_center_x($draw_start);
    my $x2 = $scale->index_to_center_x($draw_end);
    return if $x1 > $scale->{x_width} || $x2 < 0 || $x1 > $x2;

    for my $ratio (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1) {
        my $price = $p0 + ($p1 - $p0) * $ratio;
        my $y = $scale->value_to_y($price);
        next if defined $scale->{y_height} && ($y < 0 || $y > $scale->{y_height});

        $canvas->createLine( $x1, $y, $x2, $y,
            -fill => '#b2b5be', -width => 1, -dash => [2, 3],
            -tags => ['smc_overlay', 'fibonacci'],
        );
        if ( $self->_claim_label_slot( $x2 - 3, $y - 5 ) ) {
            $canvas->createText( $x2 - 3, $y - 5,
                -text => sprintf('Fib %.3g', $ratio),
                -fill => '#b2b5be', -font => ['Helvetica', 7],
                -anchor => 'e', -tags => ['smc_overlay', 'smc_label', 'fibonacci'],
            );
        }
    }
}

sub _render_market_regime {
    my ($self, $canvas, $current_bar) = @_;

    my @events;
    push @events, @{ $self->{indicator}->get_bos_events() // [] }
        if $self->{indicator}->can('get_bos_events');
    push @events, @{ $self->{indicator}->get_choch_events() // [] }
        if $self->{indicator}->can('get_choch_events');

    @events = grep { defined $_->{index} && $self->_event_visible_at($_, $current_bar) } @events;
    return unless @events;

    my ($ev) = sort { $b->{index} <=> $a->{index} } @events;
    my $dir = ($ev->{direction}//'') eq 'bull' ? 'Bullish' : 'Bearish';
    my $color = ($ev->{direction}//'') eq 'bull' ? $COLOR_BOS_BULL : $COLOR_BOS_BEAR;

    $canvas->createText( 8, 34,
        -text   => "Regime: $dir",
        -fill   => $color,
        -font   => ['Helvetica', 8, 'bold'],
        -anchor => 'w',
        -tags   => ['smc_overlay', 'smc_label', 'market_regime'],
    );
}

sub _render_fvg {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $recent_sweeps) = @_;
    $recent_sweeps //= {};
    my $fvgs = $self->{indicator}->get_fvg_zones() // [];
    my $candles = $self->{indicator}{_candles} // [];
    my $bar_w = $scale->{x_width} / ( $scale->{visible_bars} || 1 );
    my $half_bar = $bar_w * 0.5;
    my $max_fvg = int( $self->{max_fvg_visible} // 45 );
    my @candidates = grep {
        my $formed_at = $_->{formed_at};
        $formed_at = ($_->{index} // 0) + 1 unless defined $formed_at;
        my $left_idx = $_->{left_index};
        $left_idx = ($_->{index} // 0) - 1 unless defined $left_idx;
        defined $formed_at
            && $formed_at <= $current_bar
            && $left_idx <= $d_end
    } @$fvgs;
    @candidates = sort {
        ($b->{formed_at} // $b->{index} // 0) <=> ($a->{formed_at} // $a->{index} // 0)
    } @candidates;
    @candidates = @candidates[ 0 .. $max_fvg - 1 ]
        if $max_fvg > 0 && @candidates > $max_fvg;
    @candidates = sort {
        ($a->{formed_at} // $a->{index} // 0) <=> ($b->{formed_at} // $b->{index} // 0)
    } @candidates;

    my %drawn_zone;
    for my $fvg (@candidates) {
        my $idx = $fvg->{index};
        next unless defined $idx;
        my $formed_at = $fvg->{formed_at} // ($idx + 1);
        my $left_idx  = $fvg->{left_index} // ($idx - 1);
        next unless defined $formed_at;
        next unless defined $left_idx;
        next unless defined $fvg->{top} && defined $fvg->{bottom};
        next if $formed_at > $current_bar;     # no mostrar FVGs aun no confirmados en Replay

        my $max_age = $self->{fvg_max_age};
        my $max_end = defined $max_age && $max_age >= 0
            ? $formed_at + $max_age
            : $current_bar;
        my $end_idx = $current_bar < $max_end ? $current_bar : $max_end;
        my $mitigated_at = _fvg_mitigated_at(
            $fvg,
            $candles,
            $formed_at + 1,
            $end_idx,
            $self->{fvg_mitigation},
        );
        $end_idx = $mitigated_at if defined $mitigated_at && $mitigated_at < $end_idx;
        my $bounds_to = defined $mitigated_at && $mitigated_at <= $end_idx
            ? $mitigated_at - 1
            : $end_idx;
        my ($visible_top, $visible_bottom) = _fvg_visible_bounds_until(
            $fvg,
            $candles,
            $formed_at + 1,
            $bounds_to,
            $self->{fvg_mitigation},
        );
        next unless defined $visible_top && defined $visible_bottom;

        next if $end_idx < $d_start;           # el bloque ya termino antes de la vista
        next if $left_idx > $d_end;            # empieza despues de la vista

        my $draw_start = $left_idx < $d_start ? $d_start : $left_idx;
        my $draw_end   = $end_idx   > $d_end   ? $d_end   : $end_idx;
        next if $draw_start > $draw_end;

        my $age = $end_idx - $formed_at;
        my $stipple = $age <= 6  ? 'gray50'
                    : $age <= 12 ? 'gray25'
                    :              'gray12';

        my $x1 = $scale->index_to_center_x($draw_start) - $half_bar;
        my $x2 = defined $mitigated_at && $mitigated_at <= $d_end
            ? $scale->index_to_center_x($mitigated_at) + $half_bar
            : $scale->index_to_center_x($draw_end) + $half_bar;
        next if $x1 > $scale->{x_width} || $x2 < 0;
        $x1 = 0 if $x1 < 0;
        $x2 = $scale->{x_width} if $x2 > $scale->{x_width};
        next if $x2 <= $x1;

        my $yt = $scale->value_to_y( $visible_top );
        my $yb = $scale->value_to_y( $visible_bottom );
        my $y1 = $yt < $yb ? $yt : $yb;
        my $y2 = $yt < $yb ? $yb : $yt;
        my $zone_key = join ':',
            $fvg->{direction} // '',
            int(($x1 // 0) / 8),
            int(($x2 // 0) / 8),
            int(($y1 // 0) / 6),
            int(($y2 // 0) / 6);
        next if $drawn_zone{$zone_key}++;

        my $is_reaction = ($fvg->{high_reaction} // 0)
                       || $self->_fvg_high_reaction($fvg, $recent_sweeps);
        my $color = $is_reaction
            ? $COLOR_ZONE_HIGH
            : $fvg->{direction} eq 'bull' ? $COLOR_FVG_BULL : $COLOR_FVG_BEAR;
        my $outline = $is_reaction ? $COLOR_ZONE_HIGH : '';

        $canvas->createRectangle( $x1, $y1, $x2, $y2,
            -fill    => $color,
            -outline => $outline,
            -stipple => $stipple,
            -tags    => ['smc_overlay', 'fvg'],
        );

        my $lbl_y   = ($y1 + $y2) / 2;
        if ( $self->_claim_label_slot( $x1 + 3, $lbl_y ) ) {
            $canvas->createText( $x1 + 3, $lbl_y,
                -text   => 'FVG',
                -fill   => $color,
                -font   => ['Helvetica', 7, 'bold'],
                -anchor => 'w',
                -tags   => ['smc_overlay', 'smc_label', 'fvg'],
            );
        }
    }
}

sub _fvg_high_reaction {
    my ($self, $fvg, $events) = @_;
    return 0 unless $fvg && $events;

    my $formed_at = $fvg->{formed_at};
    $formed_at = ($fvg->{index} // 0) + 1 unless defined $formed_at;
    my $window = int( $self->{fvg_reaction_window} // 12 );
    $window = 0 if $window < 0;

    my $dir = $fvg->{direction} // '';
    my $wanted_side = $dir eq 'bull' ? 'sl'
                    : $dir eq 'bear' ? 'sh'
                    : '';
    return 0 if $wanted_side eq '';

    for my $idx ($formed_at - $window .. $formed_at) {
        my $by_side = $events->{$idx} // next;
        return 1 if $by_side->{$wanted_side};
    }
    return 0;
}

sub _render_order_blocks {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    return unless $self->{indicator}->can('get_ob_zones');
    my $obs     = $self->{indicator}->get_ob_zones() // [];
    my $candles = $self->{indicator}{_candles} // [];
    my $bar_w   = $scale->{x_width} / ($scale->{visible_bars} || 1);
    my $half_bar = $bar_w * 0.5;

    my @candidates = grep {
        defined $_->{confirmed_at} && $_->{confirmed_at} <= $current_bar
            && defined $_->{index}  && $_->{index} <= $d_end
            && $self->_show_structure_scope($_, $current_bar)
    } @$obs;

    @candidates = sort { ($b->{confirmed_at}//0) <=> ($a->{confirmed_at}//0) } @candidates;
    @candidates = @candidates[0..19] if @candidates > 20;
    @candidates = sort { ($a->{index}//0) <=> ($b->{index}//0) } @candidates;

    for my $ob (@candidates) {
        next unless defined $ob->{top} && defined $ob->{bottom};
        my $start_idx = ($ob->{triggered_by} // $ob->{index}) + 1;
        my $mitig = _ob_mitigated_at($ob, $candles, $start_idx, $current_bar);
        next if defined $mitig && $mitig <= $current_bar;   # OB ya mitigado: ocultar

        my $end_idx    = $current_bar;
        my $draw_start = $ob->{index} < $d_start ? $d_start : $ob->{index};
        my $draw_end   = $end_idx > $d_end ? $d_end : $end_idx;
        next if $draw_start > $draw_end || $end_idx < $d_start || $ob->{index} > $d_end;

        my $x1 = $scale->index_to_center_x($draw_start) - $half_bar;
        my $x2 = $scale->index_to_center_x($draw_end)   + $half_bar;
        next if $x1 > $scale->{x_width} || $x2 < 0 || $x2 <= $x1;

        my $yt  = $scale->value_to_y($ob->{top});
        my $yb  = $scale->value_to_y($ob->{bottom});
        my ($y1, $y2) = $yt < $yb ? ($yt, $yb) : ($yb, $yt);

        my $is_bull  = ($ob->{direction}//'') eq 'bull';
        my $scope    = $self->_effective_scope($ob, $current_bar);
        my $color    = $is_bull ? $COLOR_OB_BULL : $COLOR_OB_BEAR;
        my $stipple  = $scope eq 'external' ? 'gray50' : 'gray25';

        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill    => $color,
            -outline => $color,
            -stipple => $stipple,
            -tags    => ['smc_overlay', 'ob'],
        );
        if ($self->_claim_label_slot($x1 + 3, ($y1 + $y2) / 2)) {
            my $sc = $scope eq 'external' ? 'e' : 'i';
            $canvas->createText($x1 + 3, ($y1 + $y2) / 2,
                -text   => ($is_bull ? 'OB+' : 'OB-') . $sc,
                -fill   => $color,
                -font   => ['Helvetica', 7, 'bold'],
                -anchor => 'w',
                -tags   => ['smc_overlay', 'smc_label', 'ob'],
            );
        }
    }
}

sub _ob_mitigated_at {
    my ($ob, $candles, $from, $to) = @_;
    return undef unless $candles && @$candles;
    $from = 0        if $from < 0;
    $to   = $#$candles if $to > $#$candles;
    return undef if $from > $to;
    my $dir = $ob->{direction} // '';
    for my $i ($from .. $to) {
        my $c = $candles->[$i] // next;
        if ($dir eq 'bull') {
            return $i if defined $c->{low}  && $c->{low}  <= $ob->{top};
        } else {
            return $i if defined $c->{high} && $c->{high} >= $ob->{bottom};
        }
    }
    return undef;
}

sub _render_trendlines {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    return unless $self->{indicator}->can('get_trendlines');
    my $tls = $self->{indicator}->get_trendlines() // [];

    my @candidates = grep {
        defined $_->{confirmed_at} && $_->{confirmed_at} <= $current_bar
            && defined $_->{from_index} && $_->{from_index} <= $current_bar
            && (!defined $_->{break_at} || $_->{break_at} > $current_bar)
            && $self->_show_structure_scope($_, $current_bar)
    } @$tls;

    # Mostrar solo la ultima linea activa por direccion para evitar duplicar el ZigZag visual.
    my @bull = sort { ($b->{confirmed_at}//0) <=> ($a->{confirmed_at}//0) }
               grep { ($_->{direction}//'') eq 'bull' } @candidates;
    my @bear = sort { ($b->{confirmed_at}//0) <=> ($a->{confirmed_at}//0) }
               grep { ($_->{direction}//'') eq 'bear' } @candidates;
    @bull = @bull[0..0] if @bull > 1;
    @bear = @bear[0..0] if @bear > 1;
    @candidates = (@bull, @bear);

    for my $tl (@candidates) {
        next unless defined $tl->{from_index} && defined $tl->{to_index};
        next unless defined $tl->{from_price} && defined $tl->{to_price};
        my $span = $tl->{to_index} - $tl->{from_index};
        next if $span == 0;

        my $end_i = (defined $tl->{break_at} && $tl->{break_at} <= $current_bar)
            ? $tl->{break_at} : $current_bar;
        next if $tl->{from_index} > $d_end || $end_i < $d_start;

        my $draw_start = $tl->{from_index} < $d_start ? $d_start : $tl->{from_index};
        my $draw_end   = $end_i > $d_end ? $d_end : $end_i;
        next if $draw_start > $draw_end;

        my $slope = ($tl->{to_price} - $tl->{from_price}) / $span;
        my $p1 = $tl->{from_price} + $slope * ($draw_start - $tl->{from_index});
        my $p2 = $tl->{from_price} + $slope * ($draw_end   - $tl->{from_index});

        my $x1 = $scale->index_to_center_x($draw_start);
        my $x2 = $scale->index_to_center_x($draw_end);
        next if $x1 > $scale->{x_width} || $x2 < 0 || $x1 >= $x2;

        my $y1 = $scale->value_to_y($p1);
        my $y2 = $scale->value_to_y($p2);

        my $scope   = $self->_effective_scope($tl, $current_bar);
        my $is_bull = ($tl->{direction}//'') eq 'bull';
        my $color   = $is_bull ? $COLOR_TL_BULL : $COLOR_TL_BEAR;
        my $width   = $scope eq 'external' ? 2 : 1;
        my $broken  = defined $tl->{break_at} && $tl->{break_at} <= $current_bar;

        $canvas->createLine($x1, $y1, $x2, $y2,
            -fill  => $color,
            -width => $width,
            ($broken ? (-dash => [3, 5]) : ()),
            -tags  => ['smc_overlay', 'trendline'],
        );
    }
}

sub _fvg_mitigated_at {
    my ($fvg, $candles, $from, $to, $mode) = @_;
    return undef unless $candles && @$candles;
    return undef unless defined $fvg->{top} && defined $fvg->{bottom};
    $from = 0 if $from < 0;
    $to = $#$candles if $to > $#$candles;
    return undef if $from > $to;
    $mode //= 'full';

    my ($upper, $lower) = $fvg->{top} >= $fvg->{bottom}
        ? ($fvg->{top}, $fvg->{bottom})
        : ($fvg->{bottom}, $fvg->{top});
    my $eps = abs($upper - $lower) * 1e-8;
    $eps = 1e-8 if $eps < 1e-8;

    # Por defecto exigimos fill completo del gap:
    # bull: el precio baja hasta el borde inferior; bear: sube hasta el borde superior.
    # El modo 'touch' queda disponible si luego se quiere una vista mas agresiva.
    for my $i ($from .. $to) {
        my $c = $candles->[$i] // next;
        if ( ($fvg->{direction}//'') eq 'bull' ) {
            my $threshold = $mode eq 'touch' ? $upper : $lower;
            return $i if defined $c->{low} && $c->{low} <= $threshold + $eps;
        } else {
            my $threshold = $mode eq 'touch' ? $lower : $upper;
            return $i if defined $c->{high} && $c->{high} >= $threshold - $eps;
        }
    }
    return undef;
}

sub _fvg_visible_bounds_until {
    my ($fvg, $candles, $from, $to, $mode) = @_;
    return unless $fvg && defined $fvg->{top} && defined $fvg->{bottom};
    my ($upper, $lower) = $fvg->{top} >= $fvg->{bottom}
        ? ($fvg->{top}, $fvg->{bottom})
        : ($fvg->{bottom}, $fvg->{top});
    return ($upper, $lower) if ($mode // 'full') eq 'touch';
    return ($upper, $lower) unless $candles && @$candles;

    $from = 0 if $from < 0;
    $to = $#$candles if $to > $#$candles;
    return ($upper, $lower) if $from > $to;

    if ( ($fvg->{direction}//'') eq 'bull' ) {
        my $visible_top = $upper;
        for my $i ($from .. $to) {
            my $low = $candles->[$i]{low};
            next unless defined $low;
            next if $low >= $upper;
            $visible_top = $low if $low > $lower && $low < $visible_top;
            return if $low <= $lower;
        }
        return if $visible_top <= $lower;
        return ($visible_top, $lower);
    }

    my $visible_bottom = $lower;
    for my $i ($from .. $to) {
        my $high = $candles->[$i]{high};
        next unless defined $high;
        next if $high <= $lower;
        $visible_bottom = $high if $high < $upper && $high > $visible_bottom;
        return if $high >= $upper;
    }
    return if $visible_bottom >= $upper;
    return ($upper, $visible_bottom);
}

sub _claim_label_slot {
    my ($self, $x, $y) = @_;
    my $slot_x = int( ($x // 0) / 44 );
    my $slot_y = int( ($y // 0) / 15 );
    my $key = "$slot_x:$slot_y";
    return 0 if $self->{_label_slots}{$key};
    $self->{_label_slots}{$key} = 1;
    return 1;
}

sub _prioritize_structure_events {
    my ($self, $events, $current_bar) = @_;
    $events //= [];
    my @ready = grep {
        defined $_->{index}
            && $_->{index} <= $current_bar
            && $self->_event_visible_at($_, $current_bar)
            && $self->_show_structure_scope($_, $current_bar)
    } @$events;

    my $limit = int( $self->{max_structure_events} // 80 );
    return \@ready if $limit <= 0 || @ready <= $limit;

    @ready = sort {
        my $as = $self->_effective_scope($a, $current_bar) eq 'external' ? 1 : 0;
        my $bs = $self->_effective_scope($b, $current_bar) eq 'external' ? 1 : 0;
        $bs <=> $as || ($b->{index} // 0) <=> ($a->{index} // 0)
    } @ready;
    @ready = @ready[ 0 .. $limit - 1 ];
    @ready = sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @ready;
    return \@ready;
}

sub _structure_style {
    my ($self, $event, $current_bar, $bull_color, $bear_color) = @_;
    my $scope = $self->_effective_scope($event, $current_bar);
    my $color = ($event->{direction}//'') eq 'bull' ? $bull_color : $bear_color;
    my $width = $scope eq 'external' ? 2 : 1;
    my $dash  = $scope eq 'external' ? [6, 3] : [2, 4];
    return ($scope, $color, $width, $dash);
}

# ----------------------------------------------------------------
# BOS — linea horizontal + etiqueta "BOS" en la barra de ruptura
# ----------------------------------------------------------------
sub _render_bos {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    $current_bar //= $d_end;
    my $bos_list = $self->_prioritize_structure_events(
        $self->{indicator}->get_bos_events(), $current_bar
    );

    for my $bos (@$bos_list) {
        my $idx  = $bos->{index};
        my $from = $bos->{from};
        next unless defined $idx && defined $from && defined $bos->{level};
        next if $idx > $current_bar;                    # evento futuro en Replay
        my $line_end = $idx < $current_bar ? $idx : $current_bar;
        next if $line_end < $d_start && $from < $d_start;  # completamente fuera
        next if $from > $d_end;                            # aun no ocurrio

        my ($scope_name, $color, $width, $dash) =
            $self->_structure_style($bos, $current_bar, $COLOR_BOS_BULL, $COLOR_BOS_BEAR);
        my $y     = $scale->value_to_y( $bos->{level} );

        # Linea horizontal desde el swing original hasta la barra de ruptura
        my $x1 = $scale->index_to_center_x( $from < $d_start ? $d_start : $from );
        my $x2 = $scale->index_to_center_x( $line_end > $d_end ? $d_end : $line_end );

        next if $x1 > $scale->{x_width} || $x2 < 0;

        $canvas->createLine( $x1, $y, $x2, $y,
            -fill  => $color,
            -width => $width,
            -dash  => $dash,
            -tags  => ['smc_overlay', 'bos'],
        );

        # Etiqueta "BOS ▲" o "BOS ▼" en la barra de ruptura
        if ( $idx >= $d_start && $idx <= $d_end && $idx <= $current_bar ) {
            my $scope = $scope_name eq 'external' ? 'e' : 'i';
            my $arrow = $bos->{direction} eq 'bull' ? "BOS-$scope ^" : "BOS-$scope v";
            my $xa    = $scale->index_to_center_x($idx);
            my $offset = $bos->{direction} eq 'bull' ? -12 : 12;
            if ( $self->_claim_label_slot( $xa, $y + $offset ) ) {
                $canvas->createText( $xa, $y + $offset,
                    -text   => $arrow,
                    -fill   => $color,
                    -font   => ['Helvetica', 8, 'bold'],
                    -anchor => 'center',
                    -tags   => ['smc_overlay', 'smc_label', 'bos'],
                );
            }
        }
    }
}

# ----------------------------------------------------------------
# CHoCH — misma estructura que BOS pero colores distintos
# ----------------------------------------------------------------
sub _render_choch {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    $current_bar //= $d_end;
    return unless $self->{indicator}->can('get_choch_events');
    my $list = $self->_prioritize_structure_events(
        $self->{indicator}->get_choch_events(), $current_bar
    );
    return unless $list && @$list;

    for my $ev (@$list) {
        my $idx  = $ev->{index};
        my $from = $ev->{from};
        next unless defined $idx && defined $from && defined $ev->{level};
        next if $idx > $current_bar;
        my $line_end = $idx < $current_bar ? $idx : $current_bar;
        next if $line_end < $d_start && $from < $d_start;
        next if $from > $d_end;

        my ($scope_name, $color, $width, $dash) =
            $self->_structure_style($ev, $current_bar, $COLOR_CHOCH_BULL, $COLOR_CHOCH_BEAR);
        $width++ if ($ev->{boosted}//0) && $width < 3;
        my $y  = $scale->value_to_y( $ev->{level} );
        my $x1 = $scale->index_to_center_x( $from < $d_start ? $d_start : $from );
        my $x2 = $scale->index_to_center_x( $line_end > $d_end ? $d_end : $line_end );
        next if $x1 > $scale->{x_width} || $x2 < 0;

        $canvas->createLine( $x1, $y, $x2, $y,
            -fill => $color, -width => $width, -dash => $dash,
            -tags => ['smc_overlay', 'choch'],
        );

        if ( $idx >= $d_start && $idx <= $d_end && $idx <= $current_bar ) {
            my $xa   = $scale->index_to_center_x($idx);
            my $scope = $scope_name eq 'external' ? 'e' : 'i';
            my $lbl  = $ev->{direction} eq 'bull' ? "CHoCH-$scope ^" : "CHoCH-$scope v";
            my $yoff = $ev->{direction} eq 'bull' ? -14 : 14;
            if ( $self->_claim_label_slot( $xa, $y + $yoff ) ) {
                $canvas->createText( $xa, $y + $yoff,
                    -text => $lbl, -fill => $color,
                    -font => ['Helvetica', 8, 'bold'], -anchor => 'center',
                    -tags => ['smc_overlay', 'smc_label', 'choch'],
                );
            }
        }
    }
}

sub _event_visible_at {
    my ($self, $event, $current_bar) = @_;
    return 0 unless $event;
    return 1 unless defined $current_bar;

    my $idx = $event->{index};
    return 0 if defined $idx && $idx > $current_bar;

    my $confirmed_at = $event->{confirmed_at} // $idx;
    return 0 if defined $confirmed_at && $confirmed_at > $current_bar;

    return 1;
}

sub _effective_scope {
    my ($self, $item, $current_bar) = @_;
    return 'internal' unless $item && (($item->{scope}//'internal') eq 'external');
    return 'external' unless defined $current_bar;

    my $scope_confirmed_at = $item->{scope_confirmed_at};
    return 'external' unless defined $scope_confirmed_at;
    return $scope_confirmed_at <= $current_bar ? 'external' : 'internal';
}

sub _show_structure_scope {
    my ($self, $event, $current_bar) = @_;
    my $scope = $self->_effective_scope($event, $current_bar);
    return $scope eq 'external'
        ? $self->_visible('show_external_structure', 1)
        : $self->_visible('show_internal_structure', 1);
}

1;
