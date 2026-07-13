package Market::Overlays::VolumeProfile;

use strict;
use warnings;

# Renderizado del Perfil de Volumen sobre el Canvas de Perl/Tk.
# Dibuja barras horizontales del histograma + líneas POC/VAH/VAL.
# Lee datos de Market::Indicators::VolumeProfile — sin cálculos aquí.

my $COLOR_POC   = '#f6c90e';   # amarillo — Point of Control
my $COLOR_VAH   = '#26a69a';   # verde — Value Area High
my $COLOR_VAL   = '#ef5350';   # rojo — Value Area Low
my $COLOR_HIST  = '#4a5568';   # gris — barras de histograma
my $MAX_BAR_PX  = 80;         # ancho máximo en pixels de una barra del histograma

sub new {
    my ($class, %args) = @_;
    return bless {
        indicator  => $args{indicator},
        visibility => $args{visibility},
        max_bar_px => $args{max_bar_px} // $MAX_BAR_PX,
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

    $canvas->delete('vp_overlay');
    return unless $self->_visible('vp_enabled', 1);

    my $profiles = $ind->get_profiles() // [];
    return unless @$profiles;

    for my $profile (@$profiles) {
        next unless $profile;
        # Solo dibujar perfiles cuyo segmento sea visible
        my $p_start = $profile->{start_idx} // next;
        my $p_end   = $profile->{end_idx}   // next;
        next if $p_start > $d_end || $p_end < $d_start;
        next if $p_start > $current_bar;

        $self->_render_histogram($canvas, $d_start, $d_end, $scale, $current_bar, $profile);
        $self->_render_levels($canvas, $d_start, $d_end, $scale, $current_bar, $profile);
    }

    # Las barras del histograma deben estar debajo de las velas
    $canvas->lower('vp_hist', 'candles') if $canvas->find('withtag', 'candles');
}

# ================================================================
# Histograma horizontal de volumen
# ================================================================
sub _render_histogram {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $profile) = @_;
    my $bins    = $profile->{bins} // [];
    my $max_vol = $profile->{max_vol};
    return unless @$bins && $max_vol > 0;

    my $max_bar  = $self->{max_bar_px};
    my $p_start  = $profile->{start_idx};
    my $p_end    = $profile->{end_idx};
    my $draw_end = $p_end > $current_bar ? $current_bar : $p_end;
    $draw_end    = $d_end if $draw_end > $d_end;

    # Anclar el histograma al borde derecho del segmento
    my $x_anchor = $scale->index_to_center_x($draw_end);

    for my $bin (@$bins) {
        next unless $bin->{volume} > 0;
        my $y1 = $scale->value_to_y($bin->{price_high});
        my $y2 = $scale->value_to_y($bin->{price_low});
        ($y1, $y2) = ($y2, $y1) if $y2 < $y1;

        # Saltar si fuera del viewport vertical
        next if defined $scale->{y_height} && ($y2 < 0 || $y1 > $scale->{y_height});

        my $bar_w = ($bin->{volume} / $max_vol) * $max_bar;
        $bar_w = 2 if $bar_w < 2;

        # Histograma dibujado a la izquierda del ancla
        my $x1 = $x_anchor - $bar_w;
        my $x2 = $x_anchor;

        # Resaltar el bin del POC
        my $is_poc = abs($bin->{price} - ($profile->{poc} // 0)) < 
                     abs(($bin->{price_high} - $bin->{price_low}) / 2 + 0.001);
        my $color = $is_poc ? $COLOR_POC : $COLOR_HIST;

        $canvas->createRectangle($x1, $y1, $x2, $y2,
            -fill    => $color,
            -outline => '',
            -stipple => $is_poc ? 'gray50' : 'gray25',
            -tags    => ['vp_overlay', 'vp_hist'],
        );
    }
}

# ================================================================
# Líneas POC, VAH, VAL
# ================================================================
sub _render_levels {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $profile) = @_;
    my $p_start = $profile->{start_idx};
    my $p_end   = $profile->{end_idx};

    my $draw_start = $p_start < $d_start ? $d_start : $p_start;
    my $draw_end   = $p_end   > $d_end   ? $d_end   : $p_end;
    $draw_end = $current_bar if $draw_end > $current_bar;
    return if $draw_start > $draw_end;

    my $x1 = $scale->index_to_center_x($draw_start);
    my $x2 = $scale->index_to_center_x($draw_end);
    return if $x1 > $scale->{x_width} || $x2 < 0 || $x1 >= $x2;

    # POC
    if (defined $profile->{poc} && $self->_visible('show_vp_poc', 1)) {
        my $y = $scale->value_to_y($profile->{poc});
        if (!defined $scale->{y_height} || ($y >= -20 && $y <= $scale->{y_height} + 20)) {
            $canvas->createLine($x1, $y, $x2, $y,
                -fill  => $COLOR_POC,
                -width => 1.8,
                -dash  => [6, 3],
                -tags  => ['vp_overlay', 'vp_poc'],
            );
            $canvas->createText($x2 - 4, $y - 8,
                -text   => 'POC',
                -fill   => $COLOR_POC,
                -font   => ['Helvetica', 8, 'bold'],
                -anchor => 'e',
                -tags   => ['vp_overlay', 'vp_label'],
            );
        }
    }

    # VAH
    if (defined $profile->{vah} && $self->_visible('show_vp_vah', 1)) {
        my $y = $scale->value_to_y($profile->{vah});
        if (!defined $scale->{y_height} || ($y >= -20 && $y <= $scale->{y_height} + 20)) {
            $canvas->createLine($x1, $y, $x2, $y,
                -fill  => $COLOR_VAH,
                -width => 1.2,
                -dash  => [4, 4],
                -tags  => ['vp_overlay', 'vp_vah'],
            );
            $canvas->createText($x2 - 4, $y - 8,
                -text   => 'VAH',
                -fill   => $COLOR_VAH,
                -font   => ['Helvetica', 7, 'bold'],
                -anchor => 'e',
                -tags   => ['vp_overlay', 'vp_label'],
            );
        }
    }

    # VAL
    if (defined $profile->{val} && $self->_visible('show_vp_val', 1)) {
        my $y = $scale->value_to_y($profile->{val});
        if (!defined $scale->{y_height} || ($y >= -20 && $y <= $scale->{y_height} + 20)) {
            $canvas->createLine($x1, $y, $x2, $y,
                -fill  => $COLOR_VAL,
                -width => 1.2,
                -dash  => [4, 4],
                -tags  => ['vp_overlay', 'vp_val'],
            );
            $canvas->createText($x2 - 4, $y + 8,
                -text   => 'VAL',
                -fill   => $COLOR_VAL,
                -font   => ['Helvetica', 7, 'bold'],
                -anchor => 'e',
                -tags   => ['vp_overlay', 'vp_label'],
            );
        }
    }
}

1;
