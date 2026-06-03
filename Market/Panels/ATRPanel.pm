package Market::Panels::ATRPanel;

use strict;
use warnings;

# Renders the ATR indicator in a separate panel with its own independent scale.

my $COLOR_ATR  = '#f6c90e';
my $COLOR_GRID = '#1e2130';
my $COLOR_TEXT = '#b2b5be';

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas       => $args{canvas},
        scale_canvas => $args{scale_canvas},
        scale        => undef,
        _last_atr    => undef,
    };
    bless $self, $class;
    return $self;
}

sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# Returns [y_min, y_max] for visible ATR values with padding
sub get_y_range {
    my ($self, $values) = @_;
    my @valid = grep { defined $_ } @$values;
    return ( 0, 1 ) unless @valid;

    my $min = $valid[0];
    my $max = $valid[0];
    for my $v (@valid) {
        $min = $v if $v < $min;
        $max = $v if $v > $max;
    }
    my $pad = ( $max - $min ) * 0.15;
    $pad = 0.01 if $pad < 0.01;
    return ( 0, $max + $pad );
}

sub set_scale_range {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# Draw a single ATR segment between two consecutive defined points
sub render_atr_segment {
    my ($self, $canvas, $x1, $y1, $x2, $y2, $ix1) = @_;
    $canvas->createLine( $x1, $y1, $x2, $y2,
        -fill  => $COLOR_ATR,
        -width => 1.5,
        -tags  => [ 'atr', "as_$ix1" ],
    );
}

# Draw ATR line for visible slice
sub render {
    my ($self, $canvas, $values, $scale) = @_;
    my @valid = grep { defined $_ } @$values;
    return unless @valid;

    # Grid lines
    for my $v ( $scale->get_nice_levels() ) {
        my $y = $scale->value_to_y($v);
        next if $y < 0 || $y > $scale->{y_height};
        $canvas->createLine( 0, $y, $scale->{x_width}, $y,
            -fill => $COLOR_GRID, -tags => ['grid'] );
    }

    # ATR line: draw individual segments with per-index tags
    my ($prev_x, $prev_y, $prev_ix);
    for my $i ( 0 .. $#$values ) {
        next unless defined $values->[$i];
        my $ix = $scale->{start_index} + $i;
        my $x  = int( $scale->index_to_center_x($ix) + 0.5 );
        my $y  = int( $scale->value_to_y( $values->[$i] ) + 0.5 );

        if ( defined $prev_x ) {
            $self->render_atr_segment( $canvas, $prev_x, $prev_y, $x, $y, $prev_ix );
        }
        $prev_x  = $x;
        $prev_y  = $y;
        $prev_ix = $ix;
    }

    # Store last defined ATR value
    for my $i ( reverse 0 .. $#$values ) {
        if ( defined $values->[$i] ) {
            $self->{_last_atr} = $values->[$i];
            last;
        }
    }
}

# Draw last visible ATR value: dashed line + colored label on the right edge
sub render_last_visible_value {
    my ($self, $canvas) = @_;
    my $scale = $self->{scale};
    return unless $scale && defined $self->{_last_atr};

    my $val = $self->{_last_atr};
    my $y   = int( $scale->value_to_y($val) + 0.5 );
    return if $y < 0 || $y > $scale->{y_height};

    # Dashed horizontal line
    $canvas->createLine( 0, $y, $scale->{x_width}, $y,
        -fill  => $COLOR_ATR,
        -dash  => [ 4, 3 ],
        -tags  => ['lastatr'],
    );

    # Label box on the right edge
    my $label = sprintf( "%.4f", $val );
    my $lx    = $scale->{x_width} - 4;

    $canvas->createRectangle(
        $lx - 62, $y - 9, $lx + 2, $y + 9,
        -fill    => $COLOR_ATR,
        -outline => $COLOR_ATR,
        -tags    => ['lastatr'],
    );
    $canvas->createText(
        $lx - 30, $y,
        -text   => $label,
        -fill   => '#131722',
        -font   => [ 'Helvetica', 9, 'bold' ],
        -anchor => 'center',
        -tags   => ['lastatr'],
    );

    # Also draw on scale canvas
    my $sc = $self->{scale_canvas};
    if ($sc) {
        my $sw = $sc->width() || 75;
        $sc->createRectangle(
            0, $y - 9, $sw, $y + 9,
            -fill    => $COLOR_ATR,
            -outline => $COLOR_ATR,
            -tags    => ['lastatr'],
        );
        $sc->createText(
            $sw / 2, $y,
            -text   => $label,
            -fill   => '#131722',
            -font   => [ 'Helvetica', 9, 'bold' ],
            -anchor => 'center',
            -tags   => ['lastatr'],
        );
    }
}

# Draw crosshair on ATR panel.
# $y definido = mouse sobre ATR → dibuja linea horizontal + label en scale canvas.
# $y undef    = mouse sobre precio → solo linea vertical sincronizada.
sub draw_crosshair {
    my ($self, $x, $atr_val, $y) = @_;
    my $c     = $self->{canvas};
    my $sc    = $self->{scale_canvas};
    my $scale = $self->{scale};
    my $w     = $scale ? $scale->{x_width}  : ( $c->width()  || 900 );
    my $h     = $scale ? $scale->{y_height} : ( $c->height() || 150 );

    $c->delete('ch_atr_lines');

    # Linea vertical — siempre
    $c->createLine( $x, 0, $x, $h,
        -fill  => '#ffffff',
        -width => 1.5,
        -dash  => [ 4, 3 ],
        -tags  => [ 'crosshair', 'ch_atr_lines' ],
    );

    # Linea horizontal + caja de valor en scale canvas — solo cuando mouse sobre ATR
    $sc->delete('crosshair') if $sc;
    if ( defined $y ) {
        $c->createLine( 0, $y, $w, $y,
            -fill  => '#ffffff',
            -width => 1.5,
            -dash  => [ 4, 3 ],
            -tags  => [ 'crosshair', 'ch_atr_lines' ],
        );
        if ( $sc && $scale ) {
            my $val = $scale->y_to_value($y);
            my $sw  = $sc->width() || 75;
            $sc->createRectangle( 0, $y - 9, $sw, $y + 9,
                -fill    => '#787b86',
                -outline => '#787b86',
                -tags    => ['crosshair'],
            );
            $sc->createText( $sw / 2, $y,
                -text   => sprintf( "%.4f", $val ),
                -fill   => '#ffffff',
                -font   => [ 'Helvetica', 9, 'bold' ],
                -anchor => 'center',
                -tags   => ['crosshair'],
            );
        }
    }

    # Label del valor ATR de la barra bajo el cursor
    $c->delete('ch_atr_label');
    if ( defined $atr_val ) {
        $c->createText( 5, 12,
            -text   => sprintf( "ATR: %.4f", $atr_val ),
            -fill   => $COLOR_ATR,
            -font   => [ 'Helvetica', 9 ],
            -anchor => 'w',
            -tags   => [ 'crosshair', 'ch_atr_label' ],
        );
    }
    $c->raise('crosshair');
}

sub hide_crosshair {
    my ($self) = @_;
    $self->{canvas}->delete('ch_atr_lines');
    $self->{canvas}->delete('ch_atr_label');
    $self->{canvas}->delete('ch_atr_timelabel');
    $self->{scale_canvas}->delete('crosshair') if $self->{scale_canvas};
}

# Caja de fecha/hora en la parte inferior del panel ATR (sincronizada con el precio)
sub draw_crosshair_time_label {
    my ($self, $x, $ts) = @_;
    my $c = $self->{canvas};
    $c->delete('ch_atr_timelabel');
    return unless defined $ts;

    my @lt    = localtime($ts);
    my @meses = qw(Enero Febrero Marzo Abril Mayo Junio
                   Julio Agosto Septiembre Octubre Noviembre Diciembre);
    my $label = $meses[$lt[4]] . sprintf( " %d %02d:%02d", $lt[3], $lt[2], $lt[1] );
    my $scale = $self->{scale};
    my $y     = ( $scale ? $scale->{y_height} : ( $c->height() || 150 ) ) - 5;
    my $hw    = 62;

    $c->createRectangle( $x - $hw, $y - 9, $x + $hw, $y + 9,
        -fill    => '#131722',
        -outline => '#787b86',
        -tags    => [ 'crosshair', 'ch_atr_timelabel' ],
    );
    $c->createText( $x, $y,
        -text   => $label,
        -fill   => '#b2b5be',
        -font   => [ 'Helvetica', 8 ],
        -anchor => 'center',
        -tags   => [ 'crosshair', 'ch_atr_timelabel' ],
    );
    $c->raise('crosshair');
}

1;
