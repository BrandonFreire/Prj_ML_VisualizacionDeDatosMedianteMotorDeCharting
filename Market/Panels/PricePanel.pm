package Market::Panels::PricePanel;

use strict;
use warnings;

# Renders the main OHLC candlestick chart.
# Responsibilities: candles, price Y-axis, time X-axis, crosshair.

my $COLOR_UP   = '#26a69a';
my $COLOR_DOWN = '#ef5350';
my $COLOR_GRID = '#1e2130';
my $COLOR_AXIS = '#434651';
my $COLOR_TEXT = '#b2b5be';

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas       => $args{canvas},
        scale_canvas => $args{scale_canvas},
        scale        => undef,
        _last_close  => undef,
        _last_open   => undef,
        _ch_vline    => undef,
        _ch_hline    => undef,
        _ch_label    => undef,
    };
    bless $self, $class;
    $self->_init_crosshair_objects();
    return $self;
}

# Creates persistent crosshair canvas items (hidden initially)
sub _init_crosshair_objects {
    my ($self) = @_;
    my $c = $self->{canvas};

    $self->{_ch_vline} = $c->createLine(
        0, 0, 0, 1,
        -fill  => '#ffffff',
        -dash  => [ 3, 3 ],
        -state => 'hidden',
        -tags  => ['crosshair'],
    );
    $self->{_ch_hline} = $c->createLine(
        0, 0, 1, 0,
        -fill  => '#ffffff',
        -dash  => [ 3, 3 ],
        -state => 'hidden',
        -tags  => ['crosshair'],
    );
    $self->{_ch_label} = $c->createText(
        0, 0,
        -text   => '',
        -fill   => '#ffffff',
        -font   => [ 'Helvetica', 9 ],
        -anchor => 'w',
        -state  => 'hidden',
        -tags   => ['crosshair'],
    );
}

sub round {
    my ($self, $value) = @_;
    return int( $value + 0.5 );
}

# Store active scale (called before render)
sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
}

# Returns [y_min, y_max] for the visible data slice with padding
sub get_y_range {
    my ($self, $data) = @_;
    return ( 0, 1 ) unless @$data;

    my $min = $data->[0]{low};
    my $max = $data->[0]{high};
    for my $c (@$data) {
        $min = $c->{low}  if $c->{low}  < $min;
        $max = $c->{high} if $c->{high} > $max;
    }
    my $pad = ( $max - $min ) * 0.06;
    $pad = 0.5 if $pad < 0.5;
    return ( $min - $pad, $max + $pad );
}

# Draw a single candle with per-index tags (used by render and incremental update)
sub render_candle {
    my ($self, $canvas, $c, $ix, $scale) = @_;
    my $bar_w  = $scale->{x_width} / $scale->{visible_bars};
    my $body_w = $bar_w * 0.7;
    $body_w = 1 if $body_w < 1;

    my $x       = $self->round( $scale->index_to_center_x($ix) );
    my $y_high  = $self->round( $scale->value_to_y( $c->{high} ) );
    my $y_low   = $self->round( $scale->value_to_y( $c->{low} ) );
    my $y_open  = $self->round( $scale->value_to_y( $c->{open} ) );
    my $y_close = $self->round( $scale->value_to_y( $c->{close} ) );

    my $color = $c->{close} >= $c->{open} ? $COLOR_UP : $COLOR_DOWN;
    my $half  = int( $body_w / 2 );
    my @tags  = ( 'candles', "ci_$ix" );

    $canvas->createLine( $x, $y_high, $x, $y_low, -fill => $color, -tags => \@tags );

    my $top    = $y_open < $y_close ? $y_open  : $y_close;
    my $bottom = $y_open < $y_close ? $y_close : $y_open;
    $bottom = $top + 1 if $bottom - $top < 1;

    if ( $bar_w >= 3 ) {
        $canvas->createRectangle(
            $x - $half, $top, $x + $half, $bottom,
            -fill => $color, -outline => $color, -tags => \@tags,
        );
    }
    else {
        $canvas->createLine( $x, $top, $x, $bottom, -fill => $color, -tags => \@tags );
    }
}

# Main render: draw grid lines, then all visible candles
sub render {
    my ($self, $canvas, $data, $scale) = @_;
    return unless @$data;

    # Grid lines
    for my $v ( $scale->get_nice_levels() ) {
        my $y = $scale->value_to_y($v);
        next if $y < 0 || $y > $scale->{y_height};
        $canvas->createLine( 0, $y, $scale->{x_width}, $y,
            -fill => $COLOR_GRID, -tags => ['grid'] );
    }

    # Candles
    for my $i ( 0 .. $#$data ) {
        my $c  = $data->[$i];
        my $ix = $scale->{start_index} + $i;
        $self->render_candle( $canvas, $c, $ix, $scale );
    }

    # Store last visible candle info for render_last_visible_price
    my $last = $data->[-1];
    $self->{_last_close} = $last->{close};
    $self->{_last_open}  = $last->{open};
}

# Draw last visible close price: dashed line + colored label on the right edge
sub render_last_visible_price {
    my ($self, $canvas) = @_;
    my $scale = $self->{scale};
    return unless $scale && defined $self->{_last_close};

    my $price = $self->{_last_close};
    my $y     = $self->round( $scale->value_to_y($price) );
    return if $y < 0 || $y > $scale->{y_height};

    my $color = ( defined $self->{_last_open} && $price >= $self->{_last_open} )
        ? $COLOR_UP : $COLOR_DOWN;

    # Dashed horizontal line across the full width
    $canvas->createLine( 0, $y, $scale->{x_width}, $y,
        -fill  => $color,
        -dash  => [ 4, 3 ],
        -tags  => ['lastprice'],
    );

    # Label box on the right edge
    my $label = sprintf( "%.2f", $price );
    my $lx    = $scale->{x_width} - 4;
    my $pad   = 3;

    $canvas->createRectangle(
        $lx - 56, $y - 9, $lx + 2, $y + 9,
        -fill    => $color,
        -outline => $color,
        -tags    => ['lastprice'],
    );
    $canvas->createText(
        $lx - 27, $y,
        -text   => $label,
        -fill   => '#ffffff',
        -font   => [ 'Helvetica', 9, 'bold' ],
        -anchor => 'center',
        -tags   => ['lastprice'],
    );

    # Also draw on scale canvas
    my $sc = $self->{scale_canvas};
    if ($sc) {
        my $sw = $sc->width() || 75;
        $sc->createRectangle(
            0, $y - 9, $sw, $y + 9,
            -fill    => $color,
            -outline => $color,
            -tags    => ['lastprice'],
        );
        $sc->createText(
            $sw / 2, $y,
            -text   => $label,
            -fill   => '#ffffff',
            -font   => [ 'Helvetica', 9, 'bold' ],
            -anchor => 'center',
            -tags   => ['lastprice'],
        );
    }
}

=pod
# Alias for compatibility
sub set_y_range {
    my ($self, $y_min, $y_max) = @_;
    if ( $self->{scale} ) {
        $self->{scale}{y_min} = $y_min;
        $self->{scale}{y_max} = $y_max;
    }
}
=cut

# Draw synchronized crosshair on this panel
sub draw_crosshair {
    my ($self, $x, $y) = @_;
    my $c     = $self->{canvas};
    my $scale = $self->{scale};
    my $w     = $c->width();
    my $h     = $c->height();

    $c->coords( $self->{_ch_vline}, $x, 0, $x, $h );
    $c->coords( $self->{_ch_hline}, 0, $y, $w, $y );
    $c->itemconfigure( $self->{_ch_vline}, -state => 'normal' );
    $c->itemconfigure( $self->{_ch_hline}, -state => 'normal' );

    if ($scale) {
        my $price = $scale->y_to_value($y);
        $c->coords( $self->{_ch_label}, $w - 68, $y - 8 );
        $c->itemconfigure( $self->{_ch_label},
            -text  => sprintf( "%.2f", $price ),
            -state => 'normal',
        );
    }

    $c->raise('crosshair');
}

sub hide_crosshair {
    my ($self) = @_;
    my $c = $self->{canvas};
    $c->itemconfigure( $self->{_ch_vline}, -state => 'hidden' );
    $c->itemconfigure( $self->{_ch_hline}, -state => 'hidden' );
    $c->itemconfigure( $self->{_ch_label}, -state => 'hidden' );
}

# Draw the time axis at the bottom of the price canvas
sub draw_time_axis {
    my ($self, $canvas, $timestamps) = @_;
    my $scale = $self->{scale};
    return unless $scale && @$timestamps;

    my $h = $canvas->height();
    my $w = $canvas->width();
    my $y = $h - 28;

    $canvas->createLine( 0, $y, $w, $y, -fill => $COLOR_AXIS, -tags => ['timeaxis'] );

    my $prev_x = -999;
    for my $ts (@$timestamps) {
        my $x = $self->round( $scale->index_to_center_x( $ts->{index} ) );
        next if $x < 0 || $x > $w;
        next if abs( $x - $prev_x ) < 55;

        $canvas->createLine( $x, $y, $x, $y + 4, -fill => $COLOR_AXIS, -tags => ['timeaxis'] );
        $canvas->createText(
            $x, $y + 14,
            -text   => $ts->{label},
            -fill   => $COLOR_TEXT,
            -font   => [ 'Helvetica', 8 ],
            -anchor => 'n',
            -tags   => ['timeaxis'],
        );
        $prev_x = $x;
    }
}

1;
