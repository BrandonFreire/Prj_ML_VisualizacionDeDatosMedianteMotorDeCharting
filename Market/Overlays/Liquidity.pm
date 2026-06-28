package Market::Overlays::Liquidity;

use strict;
use warnings;

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
        indicator => $args{indicator},
        max_levels => $args{max_levels} // 5,   # cuantos niveles mostrar como maximo
        show_bsl   => $args{show_bsl}   // 1,
        show_ssl   => $args{show_ssl}   // 1,
    }, $class;
}

# Renderiza los niveles de liquidez sobre el canvas de precio.
# Solo muestra niveles NO barridos y dentro del rango visible.
sub render {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    $current_bar //= $d_end;
    my $ind = $self->{indicator};
    return unless $ind;

    $canvas->delete('lq_overlay');

    # Liquidity expone todos los niveles para poder dibujar lineas historicas cortadas
    # en swept_at y etiquetas finales en resolved_at. Fallback: swings simples de SMC.
    my ($bsl, $ssl);
    if ( $ind->can('get_levels') ) {
        my $levels = $ind->get_levels();
        $bsl = [ grep { ($_->{side}//'') eq 'sh' || ($_->{type}//'') eq 'BSL' } @$levels ];
        $ssl = [ grep { ($_->{side}//'') eq 'sl' || ($_->{type}//'') eq 'SSL' } @$levels ];
    } else {
        $bsl = $ind->get_swing_highs();
        $ssl = $ind->get_swing_lows();
    }

    $self->_render_levels( $canvas, $d_start, $d_end, $scale, $current_bar,
        $bsl, $COLOR_BSL, 'BSL', 'sh' ) if $self->{show_bsl};

    $self->_render_levels( $canvas, $d_start, $d_end, $scale, $current_bar,
        $ssl, $COLOR_SSL, 'SSL', 'sl' ) if $self->{show_ssl};
}

sub _render_levels {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $levels, $color, $tag, $side) = @_;

    for my $lvl (@$levels) {
        my $start_idx = $lvl->{start_index} // $lvl->{index};
        next unless defined $start_idx;
        next if $start_idx > $current_bar;

        my $price = $lvl->{price};
        my $y     = $scale->value_to_y($price);
        next if $y < 0 || $y > $scale->{y_height};

        my $swept_now = defined $lvl->{swept_at} && $lvl->{swept_at} <= $current_bar;
        my $line_end  = $swept_now ? $lvl->{swept_at} : $current_bar;
        $line_end = $d_end if $line_end > $d_end;

        if ( $line_end >= $d_start && $start_idx <= $d_end ) {
            my $draw_start = $start_idx < $d_start ? $d_start : $start_idx;
            my $x1 = $scale->index_to_center_x($draw_start);
            my $x2 = $scale->index_to_center_x($line_end);

            if ( $x1 <= $scale->{x_width} && $x2 >= 0 && $x1 <= $x2 ) {
                $canvas->createLine( $x1, $y, $x2, $y,
                    -fill  => $color,
                    -width => 1,
                    -dash  => [6, 4],
                    -tags  => ['lq_overlay', "lq_$tag"],
                );

                if (!$swept_now) {
                    $canvas->createText( $x2 - 4, $y - 6,
                        -text   => $tag,
                        -fill   => $color,
                        -font   => ['Helvetica', 7, 'bold'],
                        -anchor => 'e',
                        -tags   => ['lq_overlay', "lq_$tag"],
                    );
                }
            }
        }

        next unless defined $lvl->{classification};
        next unless defined $lvl->{resolved_at} && $lvl->{resolved_at} <= $current_bar;
        next if $lvl->{resolved_at} < $d_start || $lvl->{resolved_at} > $d_end;

        my ($text, $label_color) = _resolution_label($lvl, $side);
        next unless defined $text;

        my $lx = $scale->index_to_center_x($lvl->{resolved_at});
        my $ly = ($side eq 'sh') ? $y - 14 : $y + 14;
        $ly = 8 if $ly < 8;
        $ly = $scale->{y_height} - 8 if $ly > $scale->{y_height} - 8;

        $canvas->createText( $lx, $ly,
            -text   => $text,
            -fill   => $label_color,
            -font   => ['Helvetica', 8, 'bold'],
            -anchor => 'center',
            -tags   => ['lq_overlay', 'lq_resolved'],
        );
    }
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

1;
