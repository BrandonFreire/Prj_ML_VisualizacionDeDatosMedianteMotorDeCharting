package Market::Overlays::AnchoredVWAP;

use strict;
use warnings;

# Renderizado del Anchored VWAP sobre el Canvas de Perl/Tk.
# Dibuja la línea VWAP continua y sus bandas de desviación estándar.
# Lee datos de Market::Indicators::AnchoredVWAP — sin cálculos aquí.

my $COLOR_VWAP  = '#ff9800';   # Naranja principal
my $COLOR_BAND1 = '#64b5f6';   # Azul claro
my $COLOR_BAND2 = '#26a69a';   # Verde agua
my $COLOR_BAND3 = '#e57373';   # Rojo claro

sub new {
    my ($class, %args) = @_;
    return bless {
        indicator  => $args{indicator},
        visibility => $args{visibility},
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

    $canvas->delete('vwap_overlay');
    return unless $self->_visible('vwap_enabled', 1);

    my $lines = $ind->can('get_vwap_lines_at')
        ? ($ind->get_vwap_lines_at($current_bar) // [])
        : ($ind->get_vwap_lines() // []);
    return unless @$lines;

    my %label_slots;

    for my $line (@$lines) {
        my $anchor_idx = $line->{anchor_idx} // next;
        my $end_idx    = $line->{end_idx}    // next;
        my $values     = $line->{values}     // next;
        my $std_dev    = $line->{std_dev}    // [];
        my $values_offset = $line->{values_offset} // 0;
        my $m1         = $line->{mult_1}     // 1.0;
        my $m2         = $line->{mult_2}     // 2.0;
        my $m3         = $line->{mult_3}     // 3.0;

        # Saltar líneas completamente fuera del viewport
        next if $anchor_idx > $d_end || $end_idx < $d_start;
        next if $anchor_idx > $current_bar;

        my $color = $COLOR_VWAP;
        my $label = 'VWAP';

        # Construir coordenadas de la línea principal y bandas
        my (@coords_vwap, @coords_u1, @coords_l1, @coords_u2, @coords_l2, @coords_u3, @coords_l3);
        my ($last_x, $last_y);
        my $vis_end = $end_idx > $current_bar ? $current_bar : $end_idx;
        $vis_end    = $d_end if $vis_end > $d_end;
        my $vis_start = $anchor_idx < $d_start ? $d_start : $anchor_idx;

        for my $i ($vis_start .. $vis_end) {
            my $slot = $i - $values_offset;
            next if $slot < 0 || !defined $values->[$slot];
            my $x = $scale->index_to_center_x($i);
            my $v = $values->[$slot];
            my $y = $scale->value_to_y($v);
            my $sd = $std_dev->[$slot] // 0;

            # Omitir validación estricta de viewport vertical si queremos líneas que lo crucen,
            # pero por optimización filtramos lo que esté muy lejos
            my $y_u3 = $scale->value_to_y($v + $sd * $m3);
            my $y_l3 = $scale->value_to_y($v - $sd * $m3);

            next if defined $scale->{y_height} && ($y_l3 < -500 || $y_u3 > $scale->{y_height} + 500);

            push @coords_vwap, $x, $y;
            $last_x = $x;
            $last_y = $y;

            if (($line->{band_1_enabled} // 1) && $self->_visible('show_vwap_band1', 1)) {
                push @coords_u1, $x, $scale->value_to_y($v + $sd * $m1);
                push @coords_l1, $x, $scale->value_to_y($v - $sd * $m1);
            }
            if (($line->{band_2_enabled} // 1) && $self->_visible('show_vwap_band2', 1)) {
                push @coords_u2, $x, $scale->value_to_y($v + $sd * $m2);
                push @coords_l2, $x, $scale->value_to_y($v - $sd * $m2);
            }
            if (($line->{band_3_enabled} // 0) && $self->_visible('show_vwap_band3', 0)) {
                push @coords_u3, $x, $scale->value_to_y($v + $sd * $m3);
                push @coords_l3, $x, $scale->value_to_y($v - $sd * $m3);
            }
        }

        next unless @coords_vwap >= 4;

        # Dibujar VWAP principal
        $canvas->createLine(@coords_vwap,
            -fill   => $color,
            -width  => 1.5,
            -smooth => 0,
            -tags   => ['vwap_overlay', 'vwap_main'],
        );

        # Dibujar bandas
        if (@coords_u1 >= 4) {
            $canvas->createLine(@coords_u1, -fill => $COLOR_BAND1, -width => 1, -dash => [4, 4], -tags => ['vwap_overlay', 'vwap_band']);
            $canvas->createLine(@coords_l1, -fill => $COLOR_BAND1, -width => 1, -dash => [4, 4], -tags => ['vwap_overlay', 'vwap_band']);
        }
        if (@coords_u2 >= 4) {
            $canvas->createLine(@coords_u2, -fill => $COLOR_BAND2, -width => 1, -dash => [4, 4], -tags => ['vwap_overlay', 'vwap_band']);
            $canvas->createLine(@coords_l2, -fill => $COLOR_BAND2, -width => 1, -dash => [4, 4], -tags => ['vwap_overlay', 'vwap_band']);
        }
        if (@coords_u3 >= 4) {
            $canvas->createLine(@coords_u3, -fill => $COLOR_BAND3, -width => 1, -dash => [4, 4], -tags => ['vwap_overlay', 'vwap_band']);
            $canvas->createLine(@coords_l3, -fill => $COLOR_BAND3, -width => 1, -dash => [4, 4], -tags => ['vwap_overlay', 'vwap_band']);
        }

        # Etiqueta al final de la línea (evitar solapamiento)
        if (defined $last_x && defined $last_y) {
            my $slot_key = int(($last_x // 0) / 50) . ':' . int(($last_y // 0) / 18);
            unless ($label_slots{$slot_key}++) {
                $canvas->createText($last_x + 4, $last_y - 6,
                    -text   => $label,
                    -fill   => $color,
                    -font   => ['Helvetica', 7, 'bold'],
                    -anchor => 'w',
                    -tags   => ['vwap_overlay', 'vwap_label'],
                );
            }
        }
    }
}

1;
