package Market::Panels::Scales;

use strict;
use warnings;
use POSIX qw(floor);

# Coordinate transformation between data indices/values and screen pixels.
# Each panel has its own Y scale; all panels share the same X scale.
# IMPORTANT: never mix data coordinates with screen coordinates.

sub new {
    my ($class, %args) = @_;
    my $self = {
        # Horizontal (shared across panels)
        x_left       => $args{x_left}       // 0,
        x_width      => $args{x_width}       // 800,
        start_index  => $args{start_index}   // 0,
        visible_bars => $args{visible_bars}  // 100,

        # Vertical (per panel)
        y_top        => $args{y_top}         // 0,
        y_height     => $args{y_height}      // 400,
        y_min        => $args{y_min}         // 0,
        y_max        => $args{y_max}         // 1,
    };
    bless $self, $class;
    return $self;
}

# Convert data index -> screen X (center of bar)
# x_offset permite desplazamiento sub-pixel para zoom sin drift (ver ChartEngine::zoom_at)
sub index_to_x {
    my ($self, $index) = @_;
    my $bar_w  = $self->{x_width} / $self->{visible_bars};
    my $x_off  = $self->{x_offset} // 0;
    return $self->{x_left} + ( $index - $self->{start_index} + 0.5 ) * $bar_w + $x_off;
}

# Convert screen X -> data index (integer)
sub x_to_index {
    my ($self, $x) = @_;
    my $bar_w = $self->{x_width} / $self->{visible_bars};
    my $x_off = $self->{x_offset} // 0;
    return int( ( $x - $self->{x_left} - $x_off ) / $bar_w ) + $self->{start_index};
}

# Convert screen X -> data index (float, for precise crosshair)
sub x_to_index_float {
    my ($self, $x) = @_;
    my $bar_w = $self->{x_width} / $self->{visible_bars};
    my $x_off = $self->{x_offset} // 0;
    return ( $x - $self->{x_left} - $x_off ) / $bar_w + $self->{start_index};
}

# Returns the screen X of the center of a bar
sub index_to_center_x {
    my ($self, $index) = @_;
    return $self->index_to_x($index);
}

# Convert data value (price/indicator) -> screen Y
sub value_to_y {
    my ($self, $value) = @_;
    my $range = $self->{y_max} - $self->{y_min};
    return $self->{y_top} if $range == 0;
    return $self->{y_top} + ( $self->{y_max} - $value ) / $range * $self->{y_height};
}

# Convert screen Y -> data value
sub y_to_value {
    my ($self, $y) = @_;
    my $range = $self->{y_max} - $self->{y_min};
    return $self->{y_min} if $range == 0;
    return $self->{y_max} - ( $y - $self->{y_top} ) / $self->{y_height} * $range;
}

# Returns evenly spaced "nice" price levels for grid/scale labels
sub get_nice_levels {
    my ($self, $steps) = @_;
    $steps //= 6;
    return _compute_nice_levels( $self->{y_min}, $self->{y_max}, $steps );
}

# Draw price/value labels on the vertical scale canvas
sub _draw_y_scale {
    my ($self, $canvas) = @_;
    my @levels = $self->get_nice_levels();
    my $prev_y = undef;
    my $MIN_PX = 14;   # distancia minima en pixeles entre etiquetas consecutivas

    for my $v (@levels) {
        my $y = $self->value_to_y($v);
        next if $y < $self->{y_top} - 1;
        next if $y > $self->{y_top} + $self->{y_height} + 1;
        next if defined $prev_y && abs( $y - $prev_y ) < $MIN_PX;

        $canvas->createLine( 0, $y, 6, $y, -fill => '#555566' );
        $canvas->createText(
            9, $y,
            -text   => sprintf( "%.2f", $v ),
            -fill   => '#b2b5be',
            -font   => [ 'Helvetica', 9 ],
            -anchor => 'w',
        );
        $prev_y = $y;
    }
}

# --- private ---

sub _compute_nice_levels {
    my ($y_min, $y_max, $steps) = @_;
    my $range = $y_max - $y_min;
    return () if $range <= 0;

    my $raw_step = $range / $steps;
    my $mag      = 10**floor( log($raw_step) / log(10) );
    # Serie {1, 2.5, 5, 10} en lugar de {1, 2, 5, 10}:
    # genera pasos de 0.25, 2.5, 25 ... necesarios para futuros con tick de 0.25 (NQ, ES).
    my $step     = $mag;
    $step = $mag * 2.5 if $raw_step >= $mag * 1.581;
    $step = $mag * 5   if $raw_step >= $mag * 3.536;
    $step = $mag * 10  if $raw_step >= $mag * 7.071;

    my $first = floor( $y_min / $step ) * $step;
    $first += $step if $first < $y_min - 1e-9;

    my @levels;
    my $v = $first;
    while ( $v <= $y_max + 1e-9 ) {
        push @levels, $v;
        $v += $step;
    }
    return @levels;
}

1;
