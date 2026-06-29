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
my $COLOR_VOL_UP   = '#1d6f68';
my $COLOR_VOL_DOWN = '#7b343b';

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas       => $args{canvas},
        scale_canvas => $args{scale_canvas},
        scale        => undef,
        _last_close  => undef,
        _last_open   => undef,
        _volume_max  => 0,
    };
    bless $self, $class;
    return $self;
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

sub get_volume_max {
    my ($self, $data) = @_;
    my $max = 0;
    for my $c (@$data) {
        my $v = $c->{volume} // 0;
        $max = $v if $v > $max;
    }
    return $max;
}

sub render_volume_bar {
    my ($self, $canvas, $c, $ix, $scale, $volume_max) = @_;
    my $volume = $c->{volume} // 0;
    return unless $volume > 0 && $volume_max && $volume_max > 0;

    my $bar_w = $scale->{x_width} / $scale->{visible_bars};
    my $vol_w = $bar_w * 0.65;
    $vol_w = 1 if $vol_w < 1;

    my $panel_h = int( $scale->{y_height} * 0.22 );
    $panel_h = 34  if $panel_h < 34;
    $panel_h = 120 if $panel_h > 120;

    my $base_y = $scale->{y_height} - 2;
    my $h      = int( $volume / $volume_max * $panel_h + 0.5 );
    $h = 1 if $h < 1;

    my $x     = $self->round( $scale->index_to_center_x($ix) );
    my $half  = int( $vol_w / 2 );
    my $y_top = $base_y - $h;
    my $color = $c->{close} >= $c->{open} ? $COLOR_VOL_UP : $COLOR_VOL_DOWN;
    my @tags  = ( 'volume', "vi_$ix" );

    if ( $bar_w >= 2 ) {
        $canvas->createRectangle(
            $x - $half, $y_top, $x + $half, $base_y,
            -fill => $color, -outline => $color, -tags => \@tags,
        );
    }
    else {
        $canvas->createLine(
            $x, $y_top, $x, $base_y,
            -fill => $color, -tags => \@tags,
        );
    }
}

sub render_volume {
    my ($self, $canvas, $data, $scale, $volume_max) = @_;
    $volume_max //= $self->get_volume_max($data);
    $self->{_volume_max} = $volume_max;
    return unless $volume_max > 0;

    my $d_start = $scale->{data_start_index} // $scale->{start_index};
    for my $i ( 0 .. $#$data ) {
        my $ix = $d_start + $i;
        $self->render_volume_bar( $canvas, $data->[$i], $ix, $scale, $volume_max );
    }

    $canvas->lower( 'volume', 'grid' ) if $canvas->find( 'withtag', 'grid' );
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
    my ($self, $canvas, $data, $scale, $volume_max) = @_;
    return unless @$data;

    # Grid lines
    for my $v ( $scale->get_nice_levels() ) {
        my $y = $scale->value_to_y($v);
        next if $y < 0 || $y > $scale->{y_height};
        $canvas->createLine( 0, $y, $scale->{x_width}, $y,
            -fill => $COLOR_GRID, -tags => ['grid'] );
    }

    # Volume histogram, aligned to candles and kept inside the price canvas.
    $self->render_volume( $canvas, $data, $scale, $volume_max );

    # Candles
    # data_start_index es el indice real del primer elemento del slice;
    # puede diferir de start_index (virtual) cuando hay espacio vacio a la izquierda.
    my $d_start = $scale->{data_start_index} // $scale->{start_index};
    for my $i ( 0 .. $#$data ) {
        my $c  = $data->[$i];
        my $ix = $d_start + $i;
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

# Alias for compatibility
sub set_y_range {
    my ($self, $y_min, $y_max) = @_;
    if ( $self->{scale} ) {
        $self->{scale}{y_min} = $y_min;
        $self->{scale}{y_max} = $y_max;
    }
}

# Draw synchronized crosshair (delete+redraw — no stale item IDs)
# $y puede ser undef cuando el mouse esta sobre el panel ATR: solo se dibuja la linea vertical
sub draw_crosshair {
    my ($self, $x, $y) = @_;
    my $c     = $self->{canvas};
    my $sc    = $self->{scale_canvas};
    my $scale = $self->{scale};
    my $w     = $scale ? $scale->{x_width}       : ( $c->width()  || 900 );
    my $h     = $scale ? $scale->{y_height} + 30 : ( $c->height() || 500 );

    $c->delete('ch_lines');

    # Linea vertical — siempre
    $c->createLine( $x, 0, $x, $h,
        -fill  => '#ffffff',
        -width => 1.5,
        -dash  => [ 4, 3 ],
        -tags  => [ 'crosshair', 'ch_lines' ],
    );

    # Linea horizontal + label de precio — solo cuando el mouse esta sobre este panel
    if ( defined $y ) {
        $c->createLine( 0, $y, $w, $y,
            -fill  => '#ffffff',
            -width => 1.5,
            -dash  => [ 4, 3 ],
            -tags  => [ 'crosshair', 'ch_lines' ],
        );
        if ($sc && $scale) {
            my $price = $scale->y_to_value($y);
            my $sw    = $sc->width() || 75;
            $sc->delete('crosshair');
            $sc->createRectangle( 0, $y - 9, $sw, $y + 9,
                -fill => '#787b86', -outline => '#787b86', -tags => ['crosshair'] );
            $sc->createText( $sw / 2, $y,
                -text   => sprintf( "%.2f", $price ),
                -fill   => '#ffffff',
                -font   => [ 'Helvetica', 9, 'bold' ],
                -anchor => 'center',
                -tags   => ['crosshair'],
            );
        }
    }
    else {
        $sc->delete('crosshair') if $sc;
    }

    $c->raise('crosshair');
}

sub hide_crosshair {
    my ($self) = @_;
    $self->{canvas}->delete('ch_lines');
    $self->{canvas}->delete('ch_timelabel');
    $self->{canvas}->delete('ohlc_legend');
    $self->{scale_canvas}->delete('crosshair') if $self->{scale_canvas};
}

# Muestra O/H/L/C + cambio en la esquina superior izquierda del canvas de precio.
# $candle     = hashref con open/high/low/close
# $prev_close = cierre de la vela anterior (para calcular cambio); undef → usa open
sub draw_ohlc_legend {
    my ($self, $candle, $prev_close) = @_;
    my $c = $self->{canvas};
    $c->delete('ohlc_legend');
    return unless $candle;

    my ($o, $h, $l, $cl) = @{$candle}{qw(open high low close)};
    my $bar_color = $cl >= $o ? $COLOR_UP : $COLOR_DOWN;

    my $base       = defined $prev_close ? $prev_close : $o;
    my $change     = $cl - $base;
    my $pct        = $base != 0 ? $change / $base * 100 : 0;
    my $chg_color  = $change >= 0 ? $COLOR_UP : $COLOR_DOWN;
    my $chg_text   = sprintf( "%+.2f (%+.2f%%)", $change, $pct );

    my $font  = [ 'Helvetica', 10 ];
    my $y     = 14;
    my $x     = 8;
    my $GAP   = 8;   # espacio entre el valor y la siguiente letra

    for my $field ( ['O', $o], ['H', $h], ['L', $l], ['C', $cl] ) {
        my ($lbl, $val) = @$field;
        my $val_str = sprintf("%.2f", $val);

        $c->createText( $x, $y, -text => $lbl, -fill => '#787b86',
            -font => $font, -anchor => 'w', -tags => ['ohlc_legend'] );
        $x += 14;
        $c->createText( $x, $y, -text => $val_str, -fill => $bar_color,
            -font => $font, -anchor => 'w', -tags => ['ohlc_legend'] );
        # Avanzar segun longitud del texto (7px por caracter aprox en Helvetica 10)
        $x += length($val_str) * 7 + $GAP;
    }

    $c->createText( $x, $y, -text => $chg_text, -fill => $chg_color,
        -font => $font, -anchor => 'w', -tags => ['ohlc_legend'] );

    $c->raise('ohlc_legend');
}

# Caja de fecha/hora en el time-axis (delete+redraw)
sub draw_crosshair_time_label {
    my ($self, $x, $ts) = @_;
    my $scale = $self->{scale};
    return unless $scale && defined $ts;

    my @lt    = localtime($ts);
    my @meses = qw(Enero Febrero Marzo Abril Mayo Junio
                   Julio Agosto Septiembre Octubre Noviembre Diciembre);
    my $label = $meses[$lt[4]] . sprintf( " %d %02d:%02d", $lt[3], $lt[2], $lt[1] );
    my $y     = $scale->{y_height} + 14;
    my $hw    = 62;

    my $c = $self->{canvas};
    $c->delete('ch_timelabel');
    $c->createRectangle( $x - $hw, $y - 9, $x + $hw, $y + 9,
        -fill    => '#131722',
        -outline => '#787b86',
        -tags    => [ 'crosshair', 'ch_timelabel' ],
    );
    $c->createText( $x, $y,
        -text   => $label,
        -fill   => '#b2b5be',
        -font   => [ 'Helvetica', 8 ],
        -anchor => 'center',
        -tags   => [ 'crosshair', 'ch_timelabel' ],
    );
    $c->raise('crosshair');
}

# Draw the time axis at the bottom of the price canvas.
# Usa scale->y_height como posicion Y para evitar el bug donde canvas->height()
# devuelve 1 antes de que el layout este resuelto.
sub draw_time_axis {
    my ($self, $canvas, $timestamps) = @_;
    my $scale = $self->{scale};
    return unless $scale && @$timestamps;

    my $y = $scale->{y_height};
    my $w = $scale->{x_width};

    $canvas->createLine( 0, $y, $w, $y, -fill => $COLOR_AXIS, -tags => ['timeaxis'] );

    # Espaciado minimo entre labels: velas anchas = labels mas juntas, velas angostas = mas separadas
    my $min_px = 55;
    if ( ( $scale->{visible_bars} || 0 ) > 0 ) {
        my $bar_w = $scale->{x_width} / $scale->{visible_bars};
        $min_px = $bar_w > 20 ? 35 : $bar_w < 7 ? 70 : 55;
    }

    my $prev_x = -999;
    for my $ts (@$timestamps) {
        my $x = $self->round( $scale->index_to_center_x( $ts->{index} ) );
        next if $x < 0 || $x > $w;
        next if abs( $x - $prev_x ) < $min_px;

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
