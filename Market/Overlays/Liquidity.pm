package Market::Overlays::Liquidity;

use strict;
use warnings;

# Módulo de Liquidez — renderiza BSL y SSL segun la especificacion Tabla 2:
#   BSL (Buy Side Liquidity):  linea horizontal discontinua ROJA por encima de swing highs
#   SSL (Sell Side Liquidity): linea horizontal discontinua VERDE por debajo de swing lows
# Lee los swing points del indicador Market::Indicators::SMC_Structures.

my $COLOR_BSL = '#ef5350';   # rojo  — Buy Side Liquidity (stops de vendedores cortos)
my $COLOR_SSL = '#26a69a';   # verde — Sell Side Liquidity (stops de compradores)

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

    # Market::Indicators::Liquidity usa get_bsl_levels/get_ssl_levels
    # Market::Indicators::SMC_Structures usa get_swing_highs/get_swing_lows
    my $bsl = $ind->can('get_bsl_levels') ? $ind->get_bsl_levels() : $ind->get_swing_highs();
    my $ssl = $ind->can('get_ssl_levels') ? $ind->get_ssl_levels() : $ind->get_swing_lows();

    $self->_render_levels( $canvas, $d_start, $d_end, $scale, $current_bar,
        $bsl, $COLOR_BSL, 'BSL' ) if $self->{show_bsl};

    $self->_render_levels( $canvas, $d_start, $d_end, $scale, $current_bar,
        $ssl, $COLOR_SSL, 'SSL' ) if $self->{show_ssl};
}

sub _render_levels {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $levels, $color, $tag) = @_;

    # Filtrar niveles no barridos formados antes de current_bar.
    # SMC_Structures usa campo 'swept' (0/1); Liquidity usa 'state' (DETECTED/SWEPT/RESOLVED).
    my @active = grep {
        $_->{index} <= $current_bar - 1
        && ( exists $_->{swept}
             ? !$_->{swept}
             : (($_->{state}//'DETECTED') eq 'DETECTED') )
    } @$levels;

    # Tomar solo los N mas recientes (los mas relevantes)
    my $max = $self->{max_levels};
    @active = @active[ -$max .. -1 ] if @active > $max;

    for my $lvl (@active) {
        my $price = $lvl->{price};
        my $y     = $scale->value_to_y($price);
        next if $y < 0 || $y > $scale->{y_height};

        # Linea discontinua que arranca desde la barra del swing hasta el borde derecho
        my $x1 = $scale->index_to_center_x(
            $lvl->{index} < $d_start ? $d_start : $lvl->{index}
        );
        my $x2 = $scale->{x_width};

        next if $x1 > $x2;

        $canvas->createLine( $x1, $y, $x2, $y,
            -fill  => $color,
            -width => 1,
            -dash  => [6, 4],
            -tags  => ['lq_overlay', "lq_$tag"],
        );

        # Etiqueta "BSL" o "SSL" pegada al borde derecho
        $canvas->createText( $x2 - 4, $y - 6,
            -text   => $tag,
            -fill   => $color,
            -font   => ['Helvetica', 7, 'bold'],
            -anchor => 'e',
            -tags   => ['lq_overlay', "lq_$tag"],
        );
    }
}

1;
