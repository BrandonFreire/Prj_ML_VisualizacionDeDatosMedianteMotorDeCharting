package Market::Overlays::Liquidity;

use strict;
use warnings;
use utf8;

# Módulo de Liquidez — renderiza BSL y SSL segun la especificacion Tabla 2:
#   BSL (Buy Side Liquidity):  linea horizontal discontinua ROJA por encima de swing highs
#   SSL (Sell Side Liquidity): linea horizontal discontinua VERDE por debajo de swing lows
# Lee los swing points del indicador Market::Indicators::SMC_Structures.

my $COLOR_BSL = '#ef5350';   # rojo  — Buy Side Liquidity (stops de vendedores cortos)
my $COLOR_SSL = '#26a69a';   # verde — Sell Side Liquidity (stops de compradores)
my $COLOR_GRAB = '#ff9800';  # naranja — Liquidity Grab
my $COLOR_RUN  = '#2196f3';  # azul — Liquidity Run

sub new {
    my ($class, %args) = @_;
    return bless {
        indicator  => $args{indicator},
        visibility => $args{visibility},
        max_levels => $args{max_levels} // 8,   # cuantos niveles mostrar como maximo por lado
        show_bsl   => $args{show_bsl}   // 1,
        show_ssl   => $args{show_ssl}   // 1,
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

# Renderiza los niveles de liquidez sobre el canvas de precio.
# Solo muestra niveles NO barridos y dentro del rango visible.
sub render {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    $current_bar //= $d_end;
    my $ind = $self->{indicator};
    return unless $ind;

    $canvas->delete('lq_overlay');
    $self->{_label_slots} = {};
    return unless $self->_visible('liquidity_enabled', 1);

    # Liquidity expone todos los niveles para poder dibujar lineas historicas cortadas
    # en swept_at y etiquetas finales en resolved_at. Fallback: swings simples de SMC.
    my ($bsl, $ssl);
    if ( $ind->can('get_levels') ) {
        my $levels = $ind->get_levels() // [];
        $bsl = [ grep { ($_->{side}//'') eq 'sh' || ($_->{type}//'') eq 'BSL' } @$levels ];
        $ssl = [ grep { ($_->{side}//'') eq 'sl' || ($_->{type}//'') eq 'SSL' } @$levels ];
    } else {
        $bsl = $ind->can('get_swing_highs') ? $ind->get_swing_highs() : [];
        $ssl = $ind->can('get_swing_lows')  ? $ind->get_swing_lows()  : [];
    }
    $bsl = $self->_limit_levels_for_view( $bsl, $d_start, $d_end, $current_bar );
    $ssl = $self->_limit_levels_for_view( $ssl, $d_start, $d_end, $current_bar );

    $self->_render_resolution_candles( $canvas, $d_start, $d_end, $scale, $current_bar )
        if $ind->can('get_resolved');

    $self->_render_levels( $canvas, $d_start, $d_end, $scale, $current_bar,
        $bsl, $COLOR_BSL, 'BSL', 'sh' )
        if $self->{show_bsl} || $self->_visible('show_eqh', 1);

    $self->_render_levels( $canvas, $d_start, $d_end, $scale, $current_bar,
        $ssl, $COLOR_SSL, 'SSL', 'sl' )
        if $self->{show_ssl} || $self->_visible('show_eql', 1);
}

sub _limit_levels_for_view {
    my ($self, $levels, $d_start, $d_end, $current_bar) = @_;
    return [] unless $levels && @$levels;

    my $limit = int( $self->{max_levels} // 0 );

    my @visible;
    for my $lvl (@$levels) {
        my $start_idx = $lvl->{start_index} // $lvl->{index};
        next unless defined $start_idx;
        my $confirmed_at = $lvl->{confirmed_at} // $start_idx;
        next if $confirmed_at > $current_bar;
        next if $start_idx > $current_bar;
        next unless $self->_show_level_scope($lvl, $current_bar);

        my $line_end = defined $lvl->{swept_at} && $lvl->{swept_at} <= $current_bar
            ? $lvl->{swept_at}
            : $current_bar;
        next if $line_end < $d_start || $start_idx > $d_end;

        push @visible, $lvl;
    }

    return \@visible if $limit <= 0;

    @visible = sort {
        my $a_ext = $self->_effective_scope($a, $current_bar) eq 'external' ? 1 : 0;
        my $b_ext = $self->_effective_scope($b, $current_bar) eq 'external' ? 1 : 0;
        my $a_swept = defined $a->{swept_at} && $a->{swept_at} <= $current_bar ? 1 : 0;
        my $b_swept = defined $b->{swept_at} && $b->{swept_at} <= $current_bar ? 1 : 0;
        $b_ext <=> $a_ext
            || (($b_swept ? 0 : 1) <=> ($a_swept ? 0 : 1))
            || (($b->{index} // 0) <=> ($a->{index} // 0))
    } @visible;

    if ( @visible > $limit ) {
        @visible = @visible[ 0 .. $limit - 1 ];
    }

    @visible = sort { ($a->{index}//0) <=> ($b->{index}//0) } @visible;
    return \@visible;
}

sub _render_resolution_candles {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    my $candles = $self->{indicator}{_candles} // [];
    return unless $candles && @$candles;

    my $bar_w = $scale->{x_width} / ( $scale->{visible_bars} || 1 );
    my $half  = $bar_w * 0.42;
    $half = 1 if $half < 1;

    for my $lvl ( @{ $self->{indicator}->get_resolved() // [] } ) {
        next unless $self->_show_resolution($lvl);
        my $idx = $lvl->{resolved_at};
        next unless defined $idx;
        my $confirmed_at = $lvl->{confirmed_at} // $lvl->{index};
        next if defined $confirmed_at && $confirmed_at > $current_bar;
        next unless $self->_show_level_scope($lvl, $current_bar);
        next if $idx > $current_bar || $idx < $d_start || $idx > $d_end;
        my $c = $candles->[$idx] // next;
        next unless defined $c->{high} && defined $c->{low};

        my $x = $scale->index_to_center_x($idx);
        my $y1 = $scale->value_to_y($c->{high});
        my $y2 = $scale->value_to_y($c->{low});
        ($y1, $y2) = ($y2, $y1) if $y2 < $y1;

        my $class = $lvl->{classification} // '';
        my $color = $class eq 'RUN' ? $COLOR_RUN
                  : $class eq 'GRAB' ? $COLOR_GRAB
                  : (($lvl->{side}//'') eq 'sh' ? $COLOR_BSL : $COLOR_SSL);

        $canvas->createRectangle(
            $x - $half, $y1, $x + $half, $y2,
            -fill => $color, -outline => $color, -stipple => 'gray25',
            -tags => ['lq_overlay', 'lq_event_candle'],
        );
    }

    $canvas->lower( 'lq_event_candle', 'candles' )
        if $canvas->find( 'withtag', 'candles' );
}

sub _render_levels {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $levels, $color, $tag, $side) = @_;

    for my $lvl (@$levels) {
        my $start_idx = $lvl->{start_index} // $lvl->{index};
        next unless defined $start_idx;
        my $confirmed_at = $lvl->{confirmed_at} // $start_idx;
        next if $confirmed_at > $current_bar;
        next if $start_idx > $current_bar;
        next unless $self->_show_level_scope($lvl, $current_bar);

        my $price = $lvl->{price};
        next unless defined $price;
        my $y     = $scale->value_to_y($price);
        next if defined $scale->{y_height} && ($y < 0 || $y > $scale->{y_height});

        my $scope = $self->_effective_scope($lvl, $current_bar);
        my $level_label = _level_label($lvl, $tag, $side, $current_bar);
        my $line_color = $scope eq 'external' ? $color : _soft_color($color);
        my $line_width = $scope eq 'external' ? 1.4 : 1;
        my $line_dash  = $scope eq 'external' ? [6, 4] : [2, 5];
        my $show_base = $side eq 'sh'
            ? $self->_visible('show_bsl', 1)
            : $self->_visible('show_ssl', 1);
        my $show_eq = $level_label eq 'EQH'
            ? $self->_visible('show_eqh', 1)
            : $level_label eq 'EQL'
                ? $self->_visible('show_eql', 1)
                : 0;

        $self->_render_eq_connector(
            $canvas, $d_start, $d_end, $scale, $current_bar, $lvl, $color, $side, $y
        ) if $show_eq;

        my $swept_now = defined $lvl->{swept_at} && $lvl->{swept_at} <= $current_bar;
        my $line_end  = $swept_now ? $lvl->{swept_at} : $current_bar;
        my $draw_start = $start_idx < $d_start ? $d_start : $start_idx;
        my $draw_end   = $line_end  > $d_end   ? $d_end   : $line_end;

        if ( $show_base && $draw_end >= $d_start && $draw_start <= $d_end && $draw_start <= $draw_end ) {
            my $x1 = $scale->index_to_center_x($draw_start);
            my $x2 = $scale->index_to_center_x($draw_end);

            if ( $x1 <= $scale->{x_width} && $x2 >= 0 && $x1 <= $x2 ) {
                $canvas->createLine( $x1, $y, $x2, $y,
                    -fill  => $line_color,
                    -width => $line_width,
                    -dash  => $line_dash,
                    -tags  => ['lq_overlay', "lq_$tag"],
                );

                if (
                    !$swept_now
                    && $self->_claim_label_slot( $x2 - 4, $y - 6 )
                ) {
                    $canvas->createText( $x2 - 4, $y - 6,
                        -text   => $tag,
                        -fill   => $line_color,
                        -font   => ['Helvetica', 7, 'bold'],
                        -anchor => 'e',
                        -tags   => ['lq_overlay', 'lq_label', "lq_$tag", "lq_$level_label"],
                    );
                }
            }
        }

        next unless defined $lvl->{classification};
        next unless defined $lvl->{resolved_at} && $lvl->{resolved_at} <= $current_bar;
        next if $lvl->{resolved_at} < $d_start || $lvl->{resolved_at} > $d_end;

        my ($text, $label_color) = _resolution_label($lvl, $side);
        next unless defined $text;
        next unless $self->_show_resolution($lvl);

        my $lx = $scale->index_to_center_x($lvl->{resolved_at});
        my $ly = ($side eq 'sh') ? $y - 14 : $y + 14;
        $ly = 8 if $ly < 8;
        $ly = $scale->{y_height} - 8
            if defined $scale->{y_height} && $ly > $scale->{y_height} - 8;
        next unless $self->_claim_label_slot( $lx, $ly );

        $canvas->createText( $lx, $ly,
            -text   => $text,
            -fill   => $label_color,
            -font   => ['Helvetica', 8, 'bold'],
            -anchor => 'center',
            -tags   => ['lq_overlay', 'lq_label', 'lq_resolved'],
        );
    }
}

sub _render_eq_connector {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $lvl, $color, $side, $y) = @_;

    my $is_eq = ($side eq 'sh' && $lvl->{is_eqh}) || ($side eq 'sl' && $lvl->{is_eql});
    return unless $is_eq;

    my $pair_idx  = $lvl->{eq_pair};
    my $start_idx = $lvl->{start_index} // $lvl->{index};
    return unless defined $pair_idx && defined $start_idx;
    my $confirmed_at = $lvl->{confirmed_at} // $start_idx;
    my $eq_confirmed_at = $lvl->{eq_confirmed_at} // $confirmed_at;
    return if $confirmed_at > $current_bar || $eq_confirmed_at > $current_bar;
    return if $pair_idx > $current_bar || $start_idx > $current_bar;

    my $from = $pair_idx < $start_idx ? $pair_idx : $start_idx;
    my $to   = $pair_idx < $start_idx ? $start_idx : $pair_idx;
    $to = $current_bar if $to > $current_bar;

    my $draw_start = $from < $d_start ? $d_start : $from;
    my $draw_end   = $to   > $d_end   ? $d_end   : $to;
    return if $draw_start > $draw_end;

    my $x1 = $scale->index_to_center_x($draw_start);
    my $x2 = $scale->index_to_center_x($draw_end);
    return if $x1 > $scale->{x_width} || $x2 < 0 || $x1 > $x2;

    my $label = $side eq 'sh' ? 'EQH' : 'EQL';
    $canvas->createLine( $x1, $y, $x2, $y,
        -fill  => $color,
        -width => 1,
        -dash  => [2, 2],
        -tags  => ['lq_overlay', "lq_$label"],
    );

    my $lx = ($x1 + $x2) / 2;
    my $ly = $side eq 'sh' ? $y - 8 : $y + 8;
    return unless $self->_claim_label_slot( $lx, $ly );
    $canvas->createText( $lx, $ly,
        -text   => $label,
        -fill   => $color,
        -font   => ['Helvetica', 7, 'bold'],
        -anchor => 'center',
        -tags   => ['lq_overlay', 'lq_label', "lq_$label"],
    );
}

sub _claim_label_slot {
    my ($self, $x, $y) = @_;
    my $slot_x = int( ($x // 0) / 46 );
    my $slot_y = int( ($y // 0) / 16 );
    my $key = "$slot_x:$slot_y";
    return 0 if $self->{_label_slots}{$key};
    $self->{_label_slots}{$key} = 1;
    return 1;
}

sub _effective_scope {
    my ($self, $lvl, $current_bar) = @_;
    return 'internal' unless $lvl && (($lvl->{scope}//'internal') eq 'external');
    return 'external' unless defined $current_bar;

    my $scope_confirmed_at = $lvl->{scope_confirmed_at};
    return 'external' unless defined $scope_confirmed_at;
    return $scope_confirmed_at <= $current_bar ? 'external' : 'internal';
}

sub _show_level_scope {
    my ($self, $lvl, $current_bar) = @_;
    my $scope = $self->_effective_scope($lvl, $current_bar);
    return $scope eq 'external'
        ? $self->_visible('show_external_structure', 1)
        : $self->_visible('show_internal_structure', 1);
}

sub _soft_color {
    my ($color) = @_;
    return '#b66b6b' if ($color // '') eq $COLOR_BSL;
    return '#6fa99a' if ($color // '') eq $COLOR_SSL;
    return $color;
}

sub _level_label {
    my ($lvl, $tag, $side, $current_bar) = @_;
    my $eq_ready = !defined $current_bar
        || !defined $lvl->{eq_confirmed_at}
        || $lvl->{eq_confirmed_at} <= $current_bar;
    return 'EQH' if $eq_ready && $side eq 'sh' && $lvl->{is_eqh};
    return 'EQL' if $eq_ready && $side eq 'sl' && $lvl->{is_eql};
    return $tag;
}

sub _resolution_label {
    my ($lvl, $side) = @_;
    my $class = $lvl->{classification} // return;

    if ($class eq 'SWEEP') {
        return $side eq 'sh'
            ? ('SWEEP ↑', $COLOR_BSL)
            : ('SWEEP ↓', $COLOR_SSL);
    }
    return ('LQ GRAB', $COLOR_GRAB) if $class eq 'GRAB';
    return ('LQ RUN',  $COLOR_RUN)  if $class eq 'RUN';
    return;
}

sub _show_resolution {
    my ($self, $lvl) = @_;
    my $class = $lvl->{classification} // return 0;
    return $self->_visible('show_sweep', 1) if $class eq 'SWEEP';
    return $self->_visible('show_grab',  1) if $class eq 'GRAB';
    return $self->_visible('show_run',   1) if $class eq 'RUN';
    return 1;
}

1;
