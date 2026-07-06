package Market::Overlays::ZigZagDirection;

use strict;
use warnings;

my $COLOR_EXTERNAL = '#2962ff';
my $COLOR_BULL     = '#26a69a';
my $COLOR_BEAR     = '#ef5350';

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
    $canvas->delete('zz_overlay');

    my $ind = $self->{indicator};
    return unless $ind;

    if ( $self->_visible('show_zz_internal', 1) && $ind->can('get_internal_segments') ) {
        $self->_render_segments(
            $canvas, $d_start, $d_end, $scale, $current_bar,
            $ind->get_internal_segments() // [],
            undef, 2, 'zz_internal'
        );
    }

    if ( $self->_visible('show_zz_external', 1) && $ind->can('get_external_segments') ) {
        $self->_render_segments(
            $canvas, $d_start, $d_end, $scale, $current_bar,
            $ind->get_external_segments() // [],
            $COLOR_EXTERNAL, 3, 'zz_external'
        );
    }
}

sub _render_segments {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $segments, $fixed_color, $width, $tag) = @_;

    for my $seg (@$segments) {
        my $from_i = $seg->{from_index};
        my $to_i   = $seg->{to_index};
        next unless defined $from_i && defined $to_i;
        next unless defined $seg->{from_price} && defined $seg->{to_price};
        next if defined $seg->{confirmed_at} && $seg->{confirmed_at} > $current_bar;
        next if $from_i > $current_bar;

        my $draw_to = $to_i > $current_bar ? $current_bar : $to_i;
        next if $draw_to < $d_start || $from_i > $d_end;

        my $clip_from = $from_i < $d_start ? $d_start : $from_i;
        my $clip_to   = $draw_to > $d_end ? $d_end : $draw_to;
        next if $clip_from > $clip_to;

        my $p1 = _interpolate_price($seg, $clip_from);
        my $p2 = _interpolate_price($seg, $clip_to);
        next unless defined $p1 && defined $p2;

        my $x1 = $scale->index_to_center_x($clip_from);
        my $x2 = $scale->index_to_center_x($clip_to);
        next if $x1 > $scale->{x_width} || $x2 < 0;

        my $y1 = $scale->value_to_y($p1);
        my $y2 = $scale->value_to_y($p2);
        next if defined $scale->{y_height}
             && (($y1 < -60 && $y2 < -60) || ($y1 > $scale->{y_height} + 60 && $y2 > $scale->{y_height} + 60));

        my $color = $fixed_color
            || (($seg->{direction} // '') eq 'bull' ? $COLOR_BULL : $COLOR_BEAR);

        $canvas->createLine(
            $x1, $y1, $x2, $y2,
            -fill  => $color,
            -width => $width,
            -tags  => ['zz_overlay', $tag],
        );
    }
}

sub _interpolate_price {
    my ($seg, $idx) = @_;
    my $from_i = $seg->{from_index};
    my $to_i   = $seg->{to_index};
    my $from_p = $seg->{from_price};
    my $to_p   = $seg->{to_price};
    return undef unless defined $from_i && defined $to_i && defined $from_p && defined $to_p;
    return $to_p if $to_i == $from_i;
    my $t = ($idx - $from_i) / ($to_i - $from_i);
    return $from_p + ($to_p - $from_p) * $t;
}

1;
