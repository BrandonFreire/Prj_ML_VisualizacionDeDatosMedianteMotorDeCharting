package Market::Overlays::SMC_Structures;

use strict;
use warnings;

# Renderizado grafico de las estructuras SMC: BOS y FVG.
# No hace calculos — lee del indicador Market::Indicators::SMC_Structures.
# Cumple la separacion Calculo / Renderizado de la Tabla 1 de la especificacion.

my $COLOR_BOS_BULL  = '#26a69a';   # verde  — BOS alcista
my $COLOR_BOS_BEAR  = '#ef5350';   # rojo   — BOS bajista
my $COLOR_FVG_BULL  = '#26a69a';   # verde  — FVG alcista
my $COLOR_FVG_BEAR  = '#ef5350';   # rojo   — FVG bajista

sub new {
    my ($class, %args) = @_;
    return bless {
        indicator   => $args{indicator},
        show_bos    => $args{show_bos}   // 1,
        show_fvg    => $args{show_fvg}   // 1,
        fvg_max_age => $args{fvg_max_age} // 60,  # barras antes de ocultar un FVG
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

    $self->_render_fvg( $canvas, $d_start, $d_end, $scale, $current_bar ) if $self->{show_fvg};
    $self->_render_bos( $canvas, $d_start, $d_end, $scale )               if $self->{show_bos};
}

# ----------------------------------------------------------------
# FVG — rectángulos con desvanecimiento progresivo usando stipple
# ----------------------------------------------------------------
sub _render_fvg {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    my $fvgs = $self->{indicator}->get_fvg_zones();

    for my $fvg (@$fvgs) {
        my $idx = $fvg->{index};
        next if $idx > $current_bar;          # no mostrar FVGs futuros (Replay)
        next if $idx < $d_start - 1;         # totalmente fuera de la vista

        my $age = $current_bar - $idx;
        next if $age > $self->{fvg_max_age}; # FVG expirado

        # Verificar si el FVG fue "llenado" (precio entro en la zona)
        # Comprobar las barras entre idx y current_bar
        my $filled = 0;
        # (omitimos la verificacion exhaustiva para eficiencia; el stipple es suficiente para la demo)

        # Desvanecimiento progresivo mediante stipple de Tk:
        #   0-10  barras → solido (mas reciente)
        #   11-25        → gray75 (25% del fondo se ve)
        #   26-45        → gray50
        #   46+          → gray25 (casi desaparecido)
        my $stipple = '';
        if    ($age <= 10) { $stipple = ''       }
        elsif ($age <= 25) { $stipple = 'gray75' }
        elsif ($age <= 45) { $stipple = 'gray50' }
        else               { $stipple = 'gray25' }

        # Coordenadas en pantalla
        my $x1 = $scale->index_to_center_x($idx);
        # El FVG se extiende hasta el borde derecho visible o hasta current_bar
        my $x2 = $scale->index_to_center_x( $d_end < $current_bar ? $d_end : $current_bar ) + 8;

        my $y1 = $scale->value_to_y( $fvg->{top} );
        my $y2 = $scale->value_to_y( $fvg->{bottom} );

        next if $x1 > $scale->{x_width};   # fuera de pantalla a la derecha
        next if $x2 < 0;                   # fuera de pantalla a la izquierda
        $x1 = 0 if $x1 < 0;

        my $color = $fvg->{direction} eq 'bull' ? $COLOR_FVG_BULL : $COLOR_FVG_BEAR;

        if ($stipple ne '') {
            $canvas->createRectangle( $x1, $y1, $x2, $y2,
                -fill    => $color,
                -outline => '',
                -stipple => $stipple,
                -tags    => ['smc_overlay', 'fvg'],
            );
        } else {
            $canvas->createRectangle( $x1, $y1, $x2, $y2,
                -fill    => $color,
                -outline => '',
                -stipple => 'gray75',   # siempre semi-transparente para no tapar velas
                -tags    => ['smc_overlay', 'fvg'],
            );
        }

        # Etiqueta "FVG" en el borde izquierdo del recuadro
        my $lbl_y = ($y1 + $y2) / 2;
        my $lbl   = $fvg->{direction} eq 'bull' ? 'FVG' : 'FVG';
        $canvas->createText( $x1 + 3, $lbl_y,
            -text   => $lbl,
            -fill   => $color,
            -font   => ['Helvetica', 7],
            -anchor => 'w',
            -tags   => ['smc_overlay', 'fvg'],
        );
    }
}

# ----------------------------------------------------------------
# BOS — linea horizontal + etiqueta "BOS" en la barra de ruptura
# ----------------------------------------------------------------
sub _render_bos {
    my ($self, $canvas, $d_start, $d_end, $scale) = @_;
    my $bos_list = $self->{indicator}->get_bos_events();

    for my $bos (@$bos_list) {
        my $idx  = $bos->{index};
        my $from = $bos->{from};
        next if $idx  < $d_start && $from < $d_start;  # completamente fuera
        next if $from > $d_end;                         # aun no ocurrio

        my $color = $bos->{direction} eq 'bull' ? $COLOR_BOS_BULL : $COLOR_BOS_BEAR;
        my $y     = $scale->value_to_y( $bos->{level} );

        # Linea horizontal desde el swing original hasta la barra de ruptura
        my $x1 = $scale->index_to_center_x( $from < $d_start ? $d_start : $from );
        my $x2 = $scale->index_to_center_x( $idx  > $d_end   ? $d_end   : $idx  );

        next if $x1 > $scale->{x_width} || $x2 < 0;

        $canvas->createLine( $x1, $y, $x2, $y,
            -fill  => $color,
            -width => 1,
            -dash  => [4, 3],
            -tags  => ['smc_overlay', 'bos'],
        );

        # Etiqueta "BOS ▲" o "BOS ▼" en la barra de ruptura
        if ( $idx >= $d_start && $idx <= $d_end ) {
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

1;
