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
        show_bos    => $args{show_bos}   // 1,
        show_fvg    => $args{show_fvg}   // 1,
        fvg_max_age => $args{fvg_max_age} // 20,  # barras maximas hacia futuro si no hay mitigacion
    }, $class;
}

# Renderiza BOS y FVG sobre el canvas de precio.
# $current_bar = d_end (ultima barra visible, barrera en modo Replay)
sub render {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    $current_bar //= $d_end;
    my $ind = $self->{indicator};
    return unless $ind;

    $canvas->delete('smc_overlay');

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

    $self->_render_fvg( $canvas, $d_start, $d_end, $scale, $current_bar, \%recent_sweeps )
        if $self->{show_fvg};
    $self->_render_bos(   $canvas, $d_start, $d_end, $scale, $current_bar ) if $self->{show_bos};
    $self->_render_choch( $canvas, $d_start, $d_end, $scale, $current_bar );
}

# ----------------------------------------------------------------
# FVG — rectángulos con desvanecimiento progresivo usando stipple
# ----------------------------------------------------------------
sub _render_fvg {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $recent_sweeps) = @_;
    $recent_sweeps //= {};
    my $fvgs = $self->{indicator}->get_fvg_zones() // [];
    my $candles = $self->{indicator}{_candles} // [];
    my $bar_w = $scale->{x_width} / ( $scale->{visible_bars} || 1 );

    for my $fvg (@$fvgs) {
        my $idx = $fvg->{index};
        my $formed_at = $fvg->{formed_at} // $idx;
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

        my $x1 = $scale->index_to_center_x($draw_start);
        my $x2 = $scale->index_to_center_x($draw_end) + ($bar_w * 0.5);
        next if $x1 > $scale->{x_width} || $x2 < 0;
        $x1 = 0 if $x1 < 0;
        $x2 = $scale->{x_width} if $x2 > $scale->{x_width};

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

        # Verificar si este FVG coincide con un Sweep/Grab reciente (ventana de 5 barras)
        my $is_zone = 0;
        for my $si (keys %$recent_sweeps) {
            $is_zone = 1 if abs($si - $formed_at) <= 5;
        }

        # Etiqueta: "FVG" normal o "ZAR" (Zona de Alta Reaccion) si coincide con Sweep
        my $lbl_y   = ($y1 + $y2) / 2;
        my $lbl     = $is_zone ? 'ZAR' : 'FVG';
        my $lbl_clr = $is_zone ? $COLOR_ZONE_HIGH : $color;
        $canvas->createText( $x1 + 3, $lbl_y,
            -text   => $lbl,
            -fill   => $lbl_clr,
            -font   => ['Helvetica', 7, $is_zone ? 'bold' : 'normal'],
            -anchor => 'w',
            -tags   => ['smc_overlay', 'fvg'],
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

    for my $i ($from .. $to) {
        my $c = $candles->[$i] // next;
        if ( ($fvg->{direction}//'') eq 'bull' ) {
            return $i if defined $c->{low} && $c->{low} <= $fvg->{bottom};
        } else {
            return $i if defined $c->{high} && $c->{high} >= $fvg->{top};
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
            my $arrow = $bos->{direction} eq 'bull' ? 'BOS ^' : 'BOS v';
            my $xa    = $scale->index_to_center_x($idx);
            my $offset = $bos->{direction} eq 'bull' ? -12 : 12;
            $canvas->createText( $xa, $y + $offset,
                -text   => $arrow,
                -fill   => $color,
                -font   => ['Helvetica', 8, 'bold'],
                -anchor => 'center',
                -tags   => ['smc_overlay', 'bos'],
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
            my $lbl  = $ev->{direction} eq 'bull' ? 'CHoCH ^' : 'CHoCH v';
            my $yoff = $ev->{direction} eq 'bull' ? -14 : 14;
            $canvas->createText( $xa, $y + $yoff,
                -text => $lbl, -fill => $color,
                -font => ['Helvetica', 8, 'bold'], -anchor => 'center',
                -tags => ['smc_overlay', 'choch'],
            );
        }
    }
}

1;
