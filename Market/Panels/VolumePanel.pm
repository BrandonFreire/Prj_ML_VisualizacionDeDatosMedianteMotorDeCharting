package Market::Panels::VolumePanel;

use strict;
use warnings;

# Renders volume in its own panel so price overlays cannot cover it.

my $COLOR_VOL_UP   = '#1d6f68';
my $COLOR_VOL_DOWN = '#7b343b';
my $COLOR_GRID     = '#1e2130';
my $COLOR_TEXT     = '#b2b5be';

sub new {
    my ($class, %args) = @_;
    my $self = {
        canvas       => $args{canvas},
        scale_canvas => $args{scale_canvas},
        scale        => undef,
        _last_volume => undef,
    };
    bless $self, $class;
    return $self;
}

sub set_scale {
    my ($self, $scale) = @_;
    $self->{scale} = $scale;
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

sub get_y_range {
    my ($self, $data) = @_;
    my $max = $self->get_volume_max($data);
    return ( 0, 1 ) unless $max > 0;
    return ( 0, $max * 1.15 );
}

sub _format_volume {
    my ($v) = @_;
    $v //= 0;
    return sprintf( "%.1fM", $v / 1_000_000 ) if abs($v) >= 1_000_000;
    return sprintf( "%.1fK", $v / 1_000 )     if abs($v) >= 1_000;
    return sprintf( "%.0f", $v );
}

sub render_bar {
    my ($self, $canvas, $c, $ix, $scale) = @_;
    my $volume = $c->{volume} // 0;
    return unless $volume > 0;

    my $bar_w = $scale->{x_width} / ( $scale->{visible_bars} || 1 );
    my $vol_w = $bar_w * 0.65;
    $vol_w = 1 if $vol_w < 1;

    my $x      = int( $scale->index_to_center_x($ix) + 0.5 );
    my $half   = int( $vol_w / 2 );
    my $base_y = $scale->{y_height} - 1;
    my $y_top  = int( $scale->value_to_y($volume) + 0.5 );
    $y_top = 0 if $y_top < 0;
    $y_top = $base_y - 1 if $y_top >= $base_y;

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

sub render {
    my ($self, $canvas, $data, $scale) = @_;
    return unless @$data;

    for my $v ( $scale->get_nice_levels(3) ) {
        my $y = $scale->value_to_y($v);
        next if $y < 0 || $y > $scale->{y_height};
        $canvas->createLine( 0, $y, $scale->{x_width}, $y,
            -fill => $COLOR_GRID, -tags => ['grid'] );
    }

    my $d_start = $scale->{data_start_index} // $scale->{start_index};
    for my $i ( 0 .. $#$data ) {
        my $ix = $d_start + $i;
        $self->render_bar( $canvas, $data->[$i], $ix, $scale );
    }

    my $last = $data->[-1];
    $self->{_last_volume} = $last->{volume} // undef;
}

sub render_scale {
    my ($self, $scale_canvas) = @_;
    my $scale = $self->{scale};
    return unless $scale && $scale_canvas;

    $scale_canvas->delete('all');
    my $prev_y;
    for my $v ( $scale->get_nice_levels(3) ) {
        my $y = $scale->value_to_y($v);
        next if $y < -1 || $y > $scale->{y_height} + 1;
        next if defined $prev_y && abs( $y - $prev_y ) < 16;

        $scale_canvas->createLine( 0, $y, 6, $y, -fill => '#555566' );
        $scale_canvas->createText(
            9, $y,
            -text   => _format_volume($v),
            -fill   => $COLOR_TEXT,
            -font   => [ 'Helvetica', 9 ],
            -anchor => 'w',
        );
        $prev_y = $y;
    }
}

sub draw_crosshair {
    my ($self, $x, $volume, $y) = @_;
    my $c     = $self->{canvas};
    my $sc    = $self->{scale_canvas};
    my $scale = $self->{scale};
    my $w     = $scale ? $scale->{x_width}  : ( $c->width()  || 900 );
    my $h     = $scale ? $scale->{y_height} : ( $c->height() || 90 );

    $c->delete('ch_volume_lines');
    $c->createLine( $x, 0, $x, $h,
        -fill  => '#ffffff',
        -width => 1.5,
        -dash  => [ 4, 3 ],
        -tags  => [ 'crosshair', 'ch_volume_lines' ],
    );

    $sc->delete('crosshair') if $sc;
    if ( defined $y ) {
        $c->createLine( 0, $y, $w, $y,
            -fill  => '#ffffff',
            -width => 1.5,
            -dash  => [ 4, 3 ],
            -tags  => [ 'crosshair', 'ch_volume_lines' ],
        );
        if ( $sc && $scale ) {
            my $val = $scale->y_to_value($y);
            my $sw  = $sc->width() || 75;
            $sc->createRectangle( 0, $y - 9, $sw, $y + 9,
                -fill => '#787b86', -outline => '#787b86', -tags => ['crosshair'] );
            $sc->createText( $sw / 2, $y,
                -text   => _format_volume($val),
                -fill   => '#ffffff',
                -font   => [ 'Helvetica', 9, 'bold' ],
                -anchor => 'center',
                -tags   => ['crosshair'],
            );
        }
    }

    $c->delete('ch_volume_label');
    if ( defined $volume ) {
        $c->createText( 5, 12,
            -text   => 'Vol: ' . _format_volume($volume),
            -fill   => $COLOR_TEXT,
            -font   => [ 'Helvetica', 9 ],
            -anchor => 'w',
            -tags   => [ 'crosshair', 'ch_volume_label' ],
        );
    }
    $c->raise('crosshair');
}

sub hide_crosshair {
    my ($self) = @_;
    $self->{canvas}->delete('ch_volume_lines');
    $self->{canvas}->delete('ch_volume_label');
    $self->{canvas}->delete('ch_volume_timelabel');
    $self->{scale_canvas}->delete('crosshair') if $self->{scale_canvas};
}

sub draw_crosshair_time_label {
    my ($self, $x, $ts) = @_;
    my $c = $self->{canvas};
    $c->delete('ch_volume_timelabel');
    return unless defined $ts;

    my @lt    = localtime($ts);
    my @meses = qw(Enero Febrero Marzo Abril Mayo Junio
                   Julio Agosto Septiembre Octubre Noviembre Diciembre);
    my $label = $meses[$lt[4]] . sprintf( " %d %02d:%02d", $lt[3], $lt[2], $lt[1] );
    my $scale = $self->{scale};
    my $y     = ( $scale ? $scale->{y_height} : ( $c->height() || 90 ) ) - 5;
    my $hw    = 62;

    $c->createRectangle( $x - $hw, $y - 9, $x + $hw, $y + 9,
        -fill    => '#131722',
        -outline => '#787b86',
        -tags    => [ 'crosshair', 'ch_volume_timelabel' ],
    );
    $c->createText( $x, $y,
        -text   => $label,
        -fill   => $COLOR_TEXT,
        -font   => [ 'Helvetica', 8 ],
        -anchor => 'center',
        -tags   => [ 'crosshair', 'ch_volume_timelabel' ],
    );
    $c->raise('crosshair');
}

1;
