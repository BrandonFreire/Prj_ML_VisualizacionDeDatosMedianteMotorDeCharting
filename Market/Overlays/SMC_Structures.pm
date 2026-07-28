package Market::Overlays::SMC_Structures;

use strict;
use warnings;


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
        indicator        => $args{indicator},
        regime_indicator => $args{regime_indicator},
        visibility       => $args{visibility},
        show_bos       => $args{show_bos} // 1,
        show_fvg       => $args{show_fvg} // 1,
        max_structure_events => $args{max_structure_events} // 80,
        max_fvg_visible      => $args{max_fvg_visible} // 8,
        max_ob_visible       => $args{max_ob_visible} // 0,
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

sub render {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    $current_bar //= $d_end;
    my $ind = $self->{indicator};
    return unless $ind;

    $canvas->delete('smc_overlay');
    $self->{_label_slots} = {};
    return unless $self->_visible('smc_enabled', 1);

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

    if ($canvas->can('lower') && $canvas->can('find')) {
        $canvas->lower('smc_zone', 'candles')
            if $canvas->find('withtag', 'smc_zone') && $canvas->find('withtag', 'candles');
    }
}

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
    my @groups = (
        [ internal => $self->{indicator}->get_swing_highs() // [],
                     $self->{indicator}->get_swing_lows()  // [] ],
    );
    if ($self->{indicator}->can('get_external_swing_highs')) {
        push @groups, [ external =>
            $self->{indicator}->get_external_swing_highs() // [],
            $self->{indicator}->get_external_swing_lows()  // [] ];
    }

    for my $group (@groups) {
        my ($scope, $highs, $lows) = @$group;
        my $last_high;
        for my $p (@$highs) {
            my $label = defined($last_high) && $p->{price} > $last_high ? 'HH' : 'LH';
            $last_high = $p->{price};
            next unless _pivot_visible_at($p, $current_bar);
            next unless $self->_show_structure_scope($p, $current_bar);
            next if $p->{index} < $d_start || $p->{index} > $d_end;
            last if $max_labels > 0 && $labels_drawn >= $max_labels;
            my ($x, $y) = ($scale->index_to_center_x($p->{index}), $scale->value_to_y($p->{price}));
            if ($scope eq 'external'
                && (($label eq 'HH' && $show_hh) || ($label eq 'LH' && $show_lh))
                && $self->_claim_label_slot($x, $y - 10)) {
                $canvas->createText($x, $y - 10, -text=>$label, -fill=>'#f6c90e',
                    -font=>['Helvetica',7,'bold'], -anchor=>'center',
                    -tags=>['smc_overlay','smc_label',lc($label),'external_swing']);
                $labels_drawn++;
            }
            if ($show_sh && $self->_claim_label_slot($x, $y - 22)) {
                $canvas->createText($x, $y - 22, -text=>'SH',
                    -fill=>$scope eq 'external' ? '#f6c90e' : '#b2b5be',
                    -font=>['Helvetica',7,'bold'], -anchor=>'center',
                    -tags=>['smc_overlay','smc_label','sh',"${scope}_swing"]);
                $labels_drawn++;
            }
        }

        my $last_low;
        for my $p (@$lows) {
            my $label = defined($last_low) && $p->{price} > $last_low ? 'HL' : 'LL';
            $last_low = $p->{price};
            next unless _pivot_visible_at($p, $current_bar);
            next unless $self->_show_structure_scope($p, $current_bar);
            next if $p->{index} < $d_start || $p->{index} > $d_end;
            last if $max_labels > 0 && $labels_drawn >= $max_labels;
            my ($x, $y) = ($scale->index_to_center_x($p->{index}), $scale->value_to_y($p->{price}));
            if ($scope eq 'external'
                && (($label eq 'HL' && $show_hl) || ($label eq 'LL' && $show_ll))
                && $self->_claim_label_slot($x, $y + 10)) {
                $canvas->createText($x, $y + 10, -text=>$label, -fill=>'#f6c90e',
                    -font=>['Helvetica',7,'bold'], -anchor=>'center',
                    -tags=>['smc_overlay','smc_label',lc($label),'external_swing']);
                $labels_drawn++;
            }
            if ($show_sl && $self->_claim_label_slot($x, $y + 22)) {
                $canvas->createText($x, $y + 22, -text=>'SL',
                    -fill=>$scope eq 'external' ? '#f6c90e' : '#b2b5be',
                    -font=>['Helvetica',7,'bold'], -anchor=>'center',
                    -tags=>['smc_overlay','smc_label','sl',"${scope}_swing"]);
                $labels_drawn++;
            }
        }
    }
}

sub _pivot_visible_at {
    my ($pivot, $current_bar) = @_;
    return 0 unless $pivot && defined $pivot->{index} && defined $pivot->{price};
    return 0 if $pivot->{index} > $current_bar;
    return ($pivot->{confirmed_at} // $pivot->{index}) <= $current_bar ? 1 : 0;
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
        -tags => ['smc_overlay', 'smc_zone', 'premium_discount'],
    );
    $canvas->createRectangle( $x1, $y_eq, $x2, $y_low,
        -fill => '#2f5047', -outline => '',
        -stipple => 'gray12',
        -tags => ['smc_overlay', 'smc_zone', 'premium_discount'],
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
    my @external = grep { ($_->{scope}//'internal') eq 'external' } @events;
    @events = @external if @external;
    return unless @events;

    my ($ev) = sort { $b->{index} <=> $a->{index} } @events;
    my $from = $ev->{from};
    my $to   = $ev->{index};
    return if $to < $d_start || $from > $d_end;

    my $candles = $self->{indicator}->can('get_candles')
        ? $self->{indicator}->get_candles()
        : [];
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

    my $regime = $self->{regime_indicator};
    if ($regime && $regime->can('get_states')) {
        my $state = $regime->get_states()->[$current_bar];
        if ($state) {
            my %colors = (
                TR_BULLISH        => $COLOR_BOS_BULL,
                TR_BEARISH        => $COLOR_BOS_BEAR,
                TRANSITION        => $COLOR_CHOCH_BULL,
                ZM_MANIPULATION   => $COLOR_CHOCH_BEAR,
                LIQUIDEZ_EXTERNA  => $COLOR_ZONE_HIGH,
                LIQUIDEZ_INTERNA  => '#ab47bc',
                ZONA_INTERNA      => '#b2b5be',
                UNKNOWN           => '#6b7280',
            );
            my $name  = $state->{state} // 'UNKNOWN';
            my $color = $colors{$name} // '#b2b5be';
            $canvas->createText( 8, 34,
                -text   => sprintf('Regime: %s (%.0f%%)', $name,
                    100 * ($state->{confidence_score} // 0)),
                -fill   => $color,
                -font   => ['Helvetica', 8, 'bold'],
                -anchor => 'w',
                -tags   => ['smc_overlay', 'smc_label', 'market_regime'],
            );
            return;
        }
    }

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
    my $bar_w = $scale->{x_width} / ( $scale->{visible_bars} || 1 );
    my $half_body = $bar_w * 0.35;
    my $all_active = _active_fvgs_at($fvgs, $current_bar, 0);
    my @fvg_in_view  = grep { ($_->{index} // 0) >= $d_start } @$all_active;
    my @fvg_pre_view = grep { ($_->{index} // 0) <  $d_start } @$all_active;
    my $max_fvg = int($self->{max_fvg_visible} // 20);
    $max_fvg = 20 if $max_fvg <= 0;
    @fvg_in_view  = @fvg_in_view[0 .. $max_fvg - 1]          if @fvg_in_view  > $max_fvg;
    @fvg_pre_view = @fvg_pre_view[0 .. int($max_fvg/3) - 1]  if @fvg_pre_view > int($max_fvg/3);
    my @selected_list = sort {
        ($a->{formed_at}//$a->{confirmed_at}//0) <=> ($b->{formed_at}//$b->{confirmed_at}//0)
    } (@fvg_in_view, @fvg_pre_view);
    return unless @selected_list;
    for my $fvg (@selected_list) {
        my $idx = $fvg->{index};
        next unless defined $idx;
        my $formed_at = $fvg->{formed_at} // ($idx + 1);
        my $start_idx = $fvg->{mid_index} // $idx;
        next unless defined $formed_at;
        next unless defined $start_idx;
        next unless defined $fvg->{top} && defined $fvg->{bottom};
        next if $formed_at > $current_bar;

        my $end_idx = $current_bar;
        my ($visible_top, $visible_bottom) = _fvg_visible_bounds_at($fvg, $current_bar);
        next unless defined $visible_top && defined $visible_bottom;

        next if $end_idx < $d_start;
        next if $start_idx > $d_end;

        my $draw_start = $start_idx < $d_start ? $d_start : $start_idx;
        my $draw_end   = $end_idx   > $d_end   ? $d_end   : $end_idx;
        next if $draw_start > $draw_end;

        my $age = $current_bar - $formed_at;
        my $stipple = $age <= 6  ? 'gray50'
                    : $age <= 12 ? 'gray25'
                    :              'gray12';

        my $x1 = $scale->index_to_center_x($draw_start) - $half_body;
        my $x2 = $scale->index_to_center_x($draw_end) + $half_body;
        next if $x1 > $scale->{x_width} || $x2 < 0;
        $x1 = 0 if $x1 < 0;
        $x2 = $scale->{x_width} if $x2 > $scale->{x_width};
        next if $x2 <= $x1;

        my $yt = $scale->value_to_y( $visible_top );
        my $yb = $scale->value_to_y( $visible_bottom );
        my $y1 = $yt < $yb ? $yt : $yb;
        my $y2 = $yt < $yb ? $yb : $yt;
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
            -tags    => ['smc_overlay', 'smc_zone', 'fvg', 'fvg_' . ($fvg->{id} // $formed_at)],
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

sub _active_fvgs_at {
    my ($fvgs, $current_bar, $limit) = @_;
    return [] unless $fvgs && defined $current_bar;
    my @active = grep {
        my $formed = $_->{formed_at} // $_->{confirmed_at} // 9_999_999;
        my $ended  = $_->{mitigated_at} // $_->{end_index};
        $formed <= $current_bar && (!defined($ended) || $ended > $current_bar)
    } @$fvgs;

    @active = sort {
        ($b->{formed_at} // $b->{confirmed_at} // 0)
            <=> ($a->{formed_at} // $a->{confirmed_at} // 0)
        || (($b->{id} // '') cmp ($a->{id} // ''))
    } @active;
    $limit = int($limit // 0);
    @active = @active[0 .. $limit - 1] if $limit > 0 && @active > $limit;
    @active = reverse @active;
    return \@active;
}

sub _select_latest_active_fvg {
    my ($fvgs, $current_bar) = @_;
    my $active = _active_fvgs_at($fvgs, $current_bar, 1);
    return @$active ? $active->[0] : undef;
}

sub _fvg_visible_bounds_at {
    my ($fvg, $current_bar) = @_;
    return unless $fvg && defined $fvg->{top} && defined $fvg->{bottom};
    my ($top, $bottom) = ($fvg->{top}, $fvg->{bottom});
    for my $event (@{ $fvg->{fill_events} // [] }) {
        next if !defined($event->{index}) || $event->{index} > $current_bar;
        $top    = $event->{top}    if defined $event->{top};
        $bottom = $event->{bottom} if defined $event->{bottom};
    }
    return if $top <= $bottom;
    return ($top, $bottom);
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
    my $bar_w   = $scale->{x_width} / ($scale->{visible_bars} || 1);
    my $half_bar = $bar_w * 0.5;

    my @eligible = grep {
        defined $_->{confirmed_at} && $_->{confirmed_at} <= $current_bar
            && defined $_->{index}  && $_->{index} <= $current_bar
            && _ob_is_active_at($_, $current_bar)
            && $self->_show_ob_scope($_, $current_bar)
    } @$obs;

    my @in_view  = sort { (($b->{confirmed_at}//0) <=> ($a->{confirmed_at}//0))
                           || (($b->{index}//0) <=> ($a->{index}//0)) }
                   grep { ($_->{index} // 0) >= $d_start } @eligible;
    my @pre_view = sort { (($b->{confirmed_at}//0) <=> ($a->{confirmed_at}//0))
                           || (($b->{index}//0) <=> ($a->{index}//0)) }
                   grep { ($_->{index} // 0) <  $d_start } @eligible;
    my $max_ob = int($self->{max_ob_visible} // 30);
    $max_ob = 30 if $max_ob <= 0;
    @in_view  = @in_view[0 .. $max_ob - 1]        if @in_view  > $max_ob;
    @pre_view = @pre_view[0 .. int($max_ob/3) - 1] if @pre_view > int($max_ob/3);
    my @candidates = sort { ($a->{index}//0) <=> ($b->{index}//0) }
                     (@in_view, @pre_view);

    for my $ob (@candidates) {
        next unless defined $ob->{top} && defined $ob->{bottom};
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
        my $stipple  = $scope eq 'external' ? 'gray25' : 'gray12';

        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill    => $color,
            -outline => $color,
            -stipple => $stipple,
            -tags    => ['smc_overlay', 'smc_zone', 'ob', 'ob_active', "ob_$scope", 'ob_' . ($ob->{id} // $ob->{index})],
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

sub _ob_is_active_at {
    my ($ob, $current_bar) = @_;
    return 0 unless $ob && defined $current_bar;
    my $confirmed = $ob->{confirmed_at} // $ob->{triggered_by} // 9_999_999;
    my $ended = $ob->{end_index};
    return $confirmed <= $current_bar && (!defined($ended) || $ended > $current_bar) ? 1 : 0;
}

sub _render_trendlines {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    return unless $self->{indicator}->can('get_trendlines');
    my $tls = $self->{indicator}->get_trendlines() // [];

    my @candidates = grep {
        defined $_->{confirmed_at} && $_->{confirmed_at} <= $current_bar
            && defined $_->{from_index} && $_->{from_index} <= $current_bar
            && $self->_show_structure_scope($_, $current_bar)
    } @$tls;

    my %latest;
    for my $tl (@candidates) {
        my $key = join('|', $self->_effective_scope($tl, $current_bar),
                            ($tl->{direction} // ''));
        my $previous = $latest{$key};
        if (!$previous
            || ($tl->{confirmed_at} // 0) > ($previous->{confirmed_at} // 0)) {
            $latest{$key} = $tl;
        }
    }
    @candidates = values %latest;

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
    my ($self, $events, $current_bar, $skip_scope_filter) = @_;
    $events //= [];
    my @ready = grep {
        defined $_->{index}
            && $_->{index} <= $current_bar
            && $self->_event_visible_at($_, $current_bar)
            && ($skip_scope_filter || $self->_show_structure_scope($_, $current_bar))
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

sub _render_bos {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    $current_bar //= $d_end;
    my $bos_list = $self->_prioritize_structure_events(
        $self->{indicator}->get_bos_events(), $current_bar, 1
    );

    for my $bos (@$bos_list) {
        my $idx  = $bos->{index};
        my $from = $bos->{from};
        next unless defined $idx && defined $from && defined $bos->{level};
        next if $idx > $current_bar;
        my $line_end = $idx < $current_bar ? $idx : $current_bar;
        next if $line_end < $d_start && $from < $d_start;
        next if $from > $d_end;

        my ($scope_name, $color, $width, $dash) =
            $self->_structure_style($bos, $current_bar, $COLOR_BOS_BULL, $COLOR_BOS_BEAR);
        my $y     = $scale->value_to_y( $bos->{level} );

        my $x1 = $scale->index_to_center_x( $from < $d_start ? $d_start : $from );
        my $x2 = $scale->index_to_center_x( $line_end > $d_end ? $d_end : $line_end );

        next if $x1 > $scale->{x_width} || $x2 < 0;

        $canvas->createLine( $x1, $y, $x2, $y,
            -fill  => $color,
            -width => $width,
            -dash  => $dash,
            -tags  => ['smc_overlay', 'bos'],
        );

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

sub _render_choch {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    $current_bar //= $d_end;
    return unless $self->{indicator}->can('get_choch_events');
    my $list = $self->_prioritize_structure_events(
        $self->{indicator}->get_choch_events(), $current_bar, 1
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

sub _show_ob_scope {
    my ($self, $ob, $current_bar) = @_;
    my $scope = $self->_effective_scope($ob, $current_bar);
    return $scope eq 'external'
        ? $self->_visible('show_external_ob', $self->_visible('show_external_structure', 1))
        : $self->_visible('show_internal_ob', $self->_visible('show_internal_structure', 1));
}

1;
