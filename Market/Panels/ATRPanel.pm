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
        _ch_vline    => undef,
        _ch_label    => undef,
    };
    bless $self, $class;
    $self->_init_crosshair();
    return $self;
}

sub _init_crosshair {
    my ($self) = @_;
    my $c = $self->{canvas};

    $self->{_ch_vline} = $c->createLine(
        0, 0, 0, 1,
        -fill  => '#ffffff',
        -dash  => [ 3, 3 ],
        -state => 'hidden',
        -tags  => ['crosshair'],
    );
    $self->{_ch_label} = $c->createText(
        0, 0,
        -text   => '',
        -fill   => $COLOR_ATR,
        -font   => [ 'Helvetica', 9 ],
        -anchor => 'w',
        -state  => 'hidden',
        -tags   => ['crosshair'],
    );
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

# Draw vertical crosshair line synchronized with price panel
sub draw_crosshair {
    my ($self, $x, $y) = @_;
    my $c  = $self->{canvas};
    my $sc = $self->{scale};
    my $h  = $c->height();

    $c->coords( $self->{_ch_vline}, $x, 0, $x, $h );
    $c->itemconfigure( $self->{_ch_vline}, -state => 'normal' );

    if ($sc) {
        my $atr_val = $sc->y_to_value($y);
        if ( $atr_val >= $sc->{y_min} && $atr_val <= $sc->{y_max} ) {
            $c->coords( $self->{_ch_label}, 5, 5 );
            $c->itemconfigure( $self->{_ch_label},
                -text  => sprintf( "ATR: %.4f", $atr_val ),
                -state => 'normal',
            );
        }
    }

    $c->raise('crosshair');
}

sub hide_crosshair {
    my ($self) = @_;
    my $c = $self->{canvas};
    $c->itemconfigure( $self->{_ch_vline}, -state => 'hidden' );
    $c->itemconfigure( $self->{_ch_label}, -state => 'hidden' );
}

1;
