package Market::Overlays::SMC_Structures;

use strict;
use warnings;

# Renderizado grafico de las estructuras SMC: BOS y FVG.
# No hace calculos — lee del indicador Market::Indicators::SMC_Structures.
# Cumple la separacion Calculo / Renderizado de la Tabla 1 de la especificacion.

my $COLOR_BOS_BULL   = '#26a69a';   # verde  — BOS alcista
my $COLOR_BOS_BEAR   = '#ef5350';   # rojo   — BOS bajista
my $COLOR_CHOCH_BULL = '#64b5f6';   # azul claro — CHoCH alcista
my $COLOR_CHOCH_BEAR = '#ff9800';   # naranja    — CHoCH bajista
my $COLOR_FVG_BULL   = '#26a69a';   # verde  — FVG alcista
my $COLOR_FVG_BEAR   = '#ef5350';   # rojo   — FVG bajista
my $COLOR_ZONE_HIGH  = '#f6c90e';   # amarillo — Zona de Alta Reaccion

sub new {
    my ($class, %args) = @_;
    return bless {
        indicator   => $args{indicator},
        visibility  => $args{visibility},
        show_bos    => $args{show_bos}   // 1,
        show_fvg    => $args{show_fvg}   // 1,
        fvg_max_age => $args{fvg_max_age} // 20,  # barras maximas hacia futuro si no hay mitigacion
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
                $recent_sweeps{$ri} = $ev;
            }
        }
    }

    $self->_render_swing_labels( $canvas, $d_start, $d_end, $scale, $current_bar );
    $self->_render_fvg( $canvas, $d_start, $d_end, $scale, $current_bar, \%recent_sweeps )
        if $self->{show_fvg} && $self->_visible('show_fvg', 1);
    $self->_render_bos( $canvas, $d_start, $d_end, $scale, $current_bar )
        if $self->{show_bos} && $self->_visible('show_bos', 1);
    $self->_render_choch( $canvas, $d_start, $d_end, $scale, $current_bar )
        if $self->_visible('show_choch', 1);
    $self->_render_fibonacci( $canvas, $d_start, $d_end, $scale, $current_bar )
        if $self->_visible('show_fibonacci', 0);
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

    my $last_high;
    for my $sh ( @{ $self->{indicator}->get_swing_highs() // [] } ) {
        my $idx = $sh->{index};
        my $price = $sh->{price};
        next unless defined $idx && defined $price;
        next if $idx > $current_bar;

        my $label = defined $last_high && $price > $last_high ? 'HH' : 'LH';
        $last_high = $price;
        next if $idx < $d_start || $idx > $d_end;
        my $x = $scale->index_to_center_x($idx);
        my $y = $scale->value_to_y($price);
        my $scope_color = ($sh->{scope}//'') eq 'external' ? '#f6c90e' : '#b2b5be';

        if (($label eq 'HH' && $show_hh) || ($label eq 'LH' && $show_lh)) {
            $canvas->createText( $x, $y - 10,
                -text => $label, -fill => '#b2b5be',
                -font => ['Helvetica', 7, 'bold'], -anchor => 'center',
                -tags => ['smc_overlay', 'smc_label', lc($label)],
            );
        }
        if ($show_sh) {
            $canvas->createText( $x, $y - 22,
                -text => 'SH', -fill => $scope_color,
                -font => ['Helvetica', 7, 'bold'], -anchor => 'center',
                -tags => ['smc_overlay', 'smc_label', 'sh'],
            );
        }
    }

    my $last_low;
    for my $sl ( @{ $self->{indicator}->get_swing_lows() // [] } ) {
        my $idx = $sl->{index};
        my $price = $sl->{price};
        next unless defined $idx && defined $price;
        next if $idx > $current_bar;

        my $label = defined $last_low && $price > $last_low ? 'HL' : 'LL';
        $last_low = $price;
        next if $idx < $d_start || $idx > $d_end;
        my $x = $scale->index_to_center_x($idx);
        my $y = $scale->value_to_y($price);
        my $scope_color = ($sl->{scope}//'') eq 'external' ? '#f6c90e' : '#b2b5be';

        if (($label eq 'HL' && $show_hl) || ($label eq 'LL' && $show_ll)) {
            $canvas->createText( $x, $y + 10,
                -text => $label, -fill => '#b2b5be',
                -font => ['Helvetica', 7, 'bold'], -anchor => 'center',
                -tags => ['smc_overlay', 'smc_label', lc($label)],
            );
        }
        if ($show_sl) {
            $canvas->createText( $x, $y + 22,
                -text => 'SL', -fill => $scope_color,
                -font => ['Helvetica', 7, 'bold'], -anchor => 'center',
                -tags => ['smc_overlay', 'smc_label', 'sl'],
            );
        }
    }
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
            && $_->{index} <= $current_bar
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
        $canvas->createText( $x2 - 3, $y - 5,
            -text => sprintf('Fib %.3g', $ratio),
            -fill => '#b2b5be', -font => ['Helvetica', 7],
            -anchor => 'e', -tags => ['smc_overlay', 'smc_label', 'fibonacci'],
        );
    }
}

sub _render_market_regime {
    my ($self, $canvas, $current_bar) = @_;

    my @events;
    push @events, @{ $self->{indicator}->get_bos_events() // [] }
        if $self->{indicator}->can('get_bos_events');
    push @events, @{ $self->{indicator}->get_choch_events() // [] }
        if $self->{indicator}->can('get_choch_events');

    @events = grep { defined $_->{index} && $_->{index} <= $current_bar } @events;
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

    for my $fvg (@$fvgs) {
        my $idx = $fvg->{index};
        next unless defined $idx;
        my $formed_at = $fvg->{formed_at} // ($idx + 1);
        next unless defined $formed_at;
        next unless defined $fvg->{top} && defined $fvg->{bottom};
        next if $formed_at > $current_bar;     # no mostrar FVGs aun no confirmados en Replay

        my $max_age = $self->{fvg_max_age} // 20;
        my $max_end = $formed_at + $max_age;
        my $end_idx = $current_bar < $max_end ? $current_bar : $max_end;
        my $mitigated_at = _fvg_mitigated_at($fvg, $candles, $formed_at + 1, $end_idx);
        $end_idx = $mitigated_at if defined $mitigated_at && $mitigated_at < $end_idx;

        next if $end_idx < $d_start;           # el bloque ya termino antes de la vista
        next if $formed_at > $d_end;           # empieza despues de la vista

        my $draw_start = $formed_at < $d_start ? $d_start : $formed_at;
        my $draw_end   = $end_idx   > $d_end   ? $d_end   : $end_idx;
        next if $draw_start > $draw_end;

        my $age = $end_idx - $formed_at;
        my $stipple = $age <= 6  ? 'gray50'
                    : $age <= 12 ? 'gray25'
                    :              'gray12';

        my $x1 = $scale->index_to_center_x($draw_start) - $half_bar;
        my $x2 = defined $mitigated_at && $mitigated_at <= $d_end
            ? $scale->index_to_center_x($mitigated_at) - $half_bar
            : $scale->index_to_center_x($draw_end) + $half_bar;
        next if $x1 > $scale->{x_width} || $x2 < 0;
        $x1 = 0 if $x1 < 0;
        $x2 = $scale->{x_width} if $x2 > $scale->{x_width};
        next if $x2 <= $x1;

        my $yt = $scale->value_to_y( $fvg->{top} );
        my $yb = $scale->value_to_y( $fvg->{bottom} );
        my $y1 = $yt < $yb ? $yt : $yb;
        my $y2 = $yt < $yb ? $yb : $yt;

        my $color = $fvg->{direction} eq 'bull' ? $COLOR_FVG_BULL : $COLOR_FVG_BEAR;

        $canvas->createRectangle( $x1, $y1, $x2, $y2,
            -fill    => $color,
            -outline => '',
            -stipple => $stipple,
            -tags    => ['smc_overlay', 'fvg'],
        );

        my $lbl_y   = ($y1 + $y2) / 2;
        $canvas->createText( $x1 + 3, $lbl_y,
            -text   => 'FVG',
            -fill   => $color,
            -font   => ['Helvetica', 7, 'bold'],
            -anchor => 'w',
            -tags   => ['smc_overlay', 'smc_label', 'fvg'],
        );
    }
}

sub _fvg_mitigated_at {
    my ($fvg, $candles, $from, $to) = @_;
    return undef unless $candles && @$candles;
    return undef unless defined $fvg->{top} && defined $fvg->{bottom};
    $from = 0 if $from < 0;
    $to = $#$candles if $to > $#$candles;
    return undef if $from > $to;

    my ($upper, $lower) = $fvg->{top} >= $fvg->{bottom}
        ? ($fvg->{top}, $fvg->{bottom})
        : ($fvg->{bottom}, $fvg->{top});
    my $eps = abs($upper - $lower) * 1e-8;
    $eps = 1e-8 if $eps < 1e-8;

    for my $i ($from .. $to) {
        my $c = $candles->[$i] // next;
        if ( ($fvg->{direction}//'') eq 'bull' ) {
            return $i if defined $c->{low} && $c->{low} <= $lower + $eps;
        } else {
            return $i if defined $c->{high} && $c->{high} >= $upper - $eps;
        }
    }
    return undef;
}

# ----------------------------------------------------------------
# BOS — linea horizontal + etiqueta "BOS" en la barra de ruptura
# ----------------------------------------------------------------
sub _render_bos {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    $current_bar //= $d_end;
    my $bos_list = $self->{indicator}->get_bos_events();

    for my $bos (@$bos_list) {
        my $idx  = $bos->{index};
        my $from = $bos->{from};
        next unless defined $idx && defined $from && defined $bos->{level};
        next unless $self->_show_structure_scope($bos);
        next if $idx > $current_bar;                    # evento futuro en Replay
        my $line_end = $idx < $current_bar ? $idx : $current_bar;
        next if $line_end < $d_start && $from < $d_start;  # completamente fuera
        next if $from > $d_end;                            # aun no ocurrio

        my $color = $bos->{direction} eq 'bull' ? $COLOR_BOS_BULL : $COLOR_BOS_BEAR;
        my $y     = $scale->value_to_y( $bos->{level} );

        # Linea horizontal desde el swing original hasta la barra de ruptura
        my $x1 = $scale->index_to_center_x( $from < $d_start ? $d_start : $from );
        my $x2 = $scale->index_to_center_x( $line_end > $d_end ? $d_end : $line_end );

        next if $x1 > $scale->{x_width} || $x2 < 0;

        $canvas->createLine( $x1, $y, $x2, $y,
            -fill  => $color,
            -width => 1,
            -dash  => [4, 3],
            -tags  => ['smc_overlay', 'bos'],
        );

        # Etiqueta "BOS ▲" o "BOS ▼" en la barra de ruptura
        if ( $idx >= $d_start && $idx <= $d_end && $idx <= $current_bar ) {
            my $scope = ($bos->{scope}//'internal') eq 'external' ? 'e' : 'i';
            my $arrow = $bos->{direction} eq 'bull' ? "BOS-$scope ^" : "BOS-$scope v";
            my $xa    = $scale->index_to_center_x($idx);
            my $offset = $bos->{direction} eq 'bull' ? -12 : 12;
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

# ----------------------------------------------------------------
# CHoCH — misma estructura que BOS pero colores distintos
# ----------------------------------------------------------------
sub _render_choch {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    $current_bar //= $d_end;
    return unless $self->{indicator}->can('get_choch_events');
    my $list = $self->{indicator}->get_choch_events();
    return unless $list && @$list;

    for my $ev (@$list) {
        my $idx  = $ev->{index};
        my $from = $ev->{from};
        next unless defined $idx && defined $from && defined $ev->{level};
        next unless $self->_show_structure_scope($ev);
        next if $idx > $current_bar;
        my $line_end = $idx < $current_bar ? $idx : $current_bar;
        next if $line_end < $d_start && $from < $d_start;
        next if $from > $d_end;

        my $color = $ev->{direction} eq 'bull' ? $COLOR_CHOCH_BULL : $COLOR_CHOCH_BEAR;
        my $width = ($ev->{boosted}//0) ? 2 : 1;
        my $y  = $scale->value_to_y( $ev->{level} );
        my $x1 = $scale->index_to_center_x( $from < $d_start ? $d_start : $from );
        my $x2 = $scale->index_to_center_x( $line_end > $d_end ? $d_end : $line_end );
        next if $x1 > $scale->{x_width} || $x2 < 0;

        $canvas->createLine( $x1, $y, $x2, $y,
            -fill => $color, -width => $width, -dash => [6, 3],
            -tags => ['smc_overlay', 'choch'],
        );

        if ( $idx >= $d_start && $idx <= $d_end && $idx <= $current_bar ) {
            my $xa   = $scale->index_to_center_x($idx);
            my $scope = ($ev->{scope}//'internal') eq 'external' ? 'e' : 'i';
            my $lbl  = $ev->{direction} eq 'bull' ? "CHoCH-$scope ^" : "CHoCH-$scope v";
            my $yoff = $ev->{direction} eq 'bull' ? -14 : 14;
            $canvas->createText( $xa, $y + $yoff,
                -text => $lbl, -fill => $color,
                -font => ['Helvetica', 8, 'bold'], -anchor => 'center',
                -tags => ['smc_overlay', 'smc_label', 'choch'],
            );
        }
    }
}

sub _show_structure_scope {
    my ($self, $event) = @_;
    my $scope = ($event->{scope}//'internal') eq 'external' ? 'external' : 'internal';
    return $scope eq 'external'
        ? $self->_visible('show_external_structure', 1)
        : $self->_visible('show_internal_structure', 1);
}

1;
