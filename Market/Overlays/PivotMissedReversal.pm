package Market::Overlays::PivotMissedReversal;

use strict;
use warnings;
use utf8;


my $COLOR_HIGH         = '#ef5350';
my $COLOR_LOW          = '#26a69a';
my $COLOR_REGULAR_HIGH = '#e57373';
my $COLOR_REGULAR_LOW  = '#4db6ac';
my $COLOR_EYE          = '#131722';

sub new {
    my ($class, %args) = @_;
    return bless {
        indicator  => $args{indicator},
        visibility => $args{visibility},
        max_labels => $args{max_labels} // 120,
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
    $canvas->delete('pmr_overlay');

    my $ind = $self->{indicator};
    return unless $ind && $scale;
    return unless $self->_visible('pmr_enabled', 1);

    my $regular = $ind->can('get_regular_pivots')
        ? ($ind->get_regular_pivots() // []) : [];
    my $missed = $ind->can('get_missed_pivots')
        ? ($ind->get_missed_pivots() // []) : [];
    my $levels = $ind->can('get_reversal_levels')
        ? ($ind->get_reversal_levels() // []) : [];
    my $traces = $ind->can('get_trace_events')
        ? ($ind->get_trace_events() // []) : [];

    my @regular_visible = grep {
        _pivot_visible_at($_, $current_bar)
    } @$regular;
    my @missed_visible = grep {
        _pivot_visible_at($_, $current_bar)
    } @$missed;

    $self->_render_segments(
        $canvas, $d_start, $d_end, $scale, $current_bar,
        [ @regular_visible, @missed_visible ],
    ) if $self->_visible('show_pmr_segments', 0);

    $self->_render_levels(
        $canvas, $d_start, $d_end, $scale, $current_bar, $levels,
    ) if $self->_visible('show_pmr_levels', 1);

    $self->_render_regular_pivots(
        $canvas, $d_start, $d_end, $scale, \@regular_visible,
    ) if $self->_visible('show_pmr_regular', 0);

    $self->_render_missed_pivots(
        $canvas, $d_start, $d_end, $scale, \@missed_visible,
    ) if $self->_visible('show_pmr_missed', 1);

    $self->_render_traces(
        $canvas, $d_start, $d_end, $scale, $current_bar, $traces,
    ) if $self->_visible('show_pmr_traces', 0);

    if ($self->_visible('show_pmr_provisional', 1)) {
        my $provisional = $ind->can('get_provisional_pivot_at')
            ? $ind->get_provisional_pivot_at($current_bar)
            : $ind->can('get_provisional_pivot')
                ? $ind->get_provisional_pivot() : undef;
        $self->_render_provisional(
            $canvas, $d_start, $d_end, $scale, $current_bar, $provisional,
        ) if $provisional;
    }
}

sub _render_traces {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $traces) = @_;
    my @visible = grep {
        defined($_->{event_index}) && $_->{event_index} <= $current_bar
            && defined($_->{ghost_index}) && defined($_->{ghost_price})
            && $_->{ghost_index} >= $d_start && $_->{ghost_index} <= $d_end
    } @$traces;
    if ($self->{max_labels} > 0 && @visible > $self->{max_labels}) {
        @visible = @visible[-$self->{max_labels} .. -1];
    }
    for my $trace (@visible) {
        my $x = $scale->index_to_center_x($trace->{ghost_index});
        my $price_y = $scale->value_to_y($trace->{ghost_price});
        next if _outside_y($scale, $price_y, 24);
        my $is_high = ($trace->{ghost_type} // '') eq 'high';
        my $y = $price_y + ($is_high ? -13 : 13);
        $canvas->createText(
            $x, $y,
            -text => '1',
            -fill => _type_color($trace->{ghost_type}),
            -font => [ 'Helvetica', 8, 'bold' ],
            -tags => [ 'pmr_overlay', 'pmr_label', 'pmr_trace' ],
        );
    }
}

sub _render_levels {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $levels) = @_;
    for my $level (@$levels) {
        next unless $level && defined $level->{price};
        my $created_at = $level->{created_at} // $level->{confirmed_at};
        next unless defined $created_at && $created_at <= $current_bar;

        my $start = $level->{start_index} // $level->{index};
        next unless defined $start && $start <= $current_bar;
        my $end = $level->{end_index};
        $end = $current_bar unless defined $end;
        $end = $current_bar if $end > $current_bar;
        next if $end < $d_start || $start > $d_end;

        my $draw_start = $start < $d_start ? $d_start : $start;
        my $draw_end   = $end > $d_end ? $d_end : $end;
        next if $draw_start > $draw_end;

        my $y = $scale->value_to_y($level->{price});
        next if _outside_y($scale, $y, 20);
        my $x1 = $scale->index_to_center_x($draw_start);
        my $x2 = $scale->index_to_center_x($draw_end);
        my $color = _type_color($level->{type});
        my $active_at_cursor = $level->{active}
            || (($level->{end_index} // $current_bar) > $current_bar);

        $canvas->createLine(
            $x1, $y, $x2, $y,
            -fill  => $color,
            -width => $active_at_cursor ? 2 : 1,
            -dash  => $active_at_cursor ? [6, 3] : [3, 4],
            -tags  => [ 'pmr_overlay', 'pmr_line', 'pmr_level' ],
        );
    }
}

sub _render_regular_pivots {
    my ($self, $canvas, $d_start, $d_end, $scale, $pivots) = @_;
    my $drawn = 0;
    for my $pivot (sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @$pivots) {
        last if $self->{max_labels} > 0 && $drawn >= $self->{max_labels};
        my ($idx, $price, $type) = @{$pivot}{qw(index price type)};
        next unless defined $idx && defined $price;
        next if $idx < $d_start || $idx > $d_end;

        my $x = $scale->index_to_center_x($idx);
        my $y = $scale->value_to_y($price);
        next if _outside_y($scale, $y, 18);
        my ($color, @points);
        if (($type // '') eq 'high') {
            $color = $COLOR_REGULAR_HIGH;
            @points = ($x - 4, $y - 14, $x + 4, $y - 14, $x, $y - 6);
        }
        else {
            $color = $COLOR_REGULAR_LOW;
            @points = ($x - 4, $y + 14, $x + 4, $y + 14, $x, $y + 6);
        }
        $canvas->createPolygon(
            @points,
            -fill    => $color,
            -outline => $COLOR_EYE,
            -tags    => [ 'pmr_overlay', 'pmr_label', 'pmr_regular' ],
        );
        $drawn++;
    }
}

sub _render_missed_pivots {
    my ($self, $canvas, $d_start, $d_end, $scale, $pivots) = @_;
    my $drawn = 0;
    for my $pivot (sort { ($a->{index} // 0) <=> ($b->{index} // 0) } @$pivots) {
        last if $self->{max_labels} > 0 && $drawn >= $self->{max_labels};
        my ($idx, $price, $type) = @{$pivot}{qw(index price type)};
        next unless defined $idx && defined $price;
        next if $idx < $d_start || $idx > $d_end;

        my $x = $scale->index_to_center_x($idx);
        my $price_y = $scale->value_to_y($price);
        next if _outside_y($scale, $price_y, 30);
        my $cy = ($type // '') eq 'high' ? $price_y - 19 : $price_y + 19;
        if (defined $scale->{y_height}) {
            $cy = 10 if $cy < 10;
            $cy = $scale->{y_height} - 10 if $cy > $scale->{y_height} - 10;
        }
        $self->_draw_ghost($canvas, $x, $cy, _type_color($type));
        $drawn++;
    }
}

sub _render_provisional {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $pivot) = @_;
    return unless $pivot && defined $pivot->{index} && defined $pivot->{price};
    return if $pivot->{index} > $current_bar;

    my $idx   = $pivot->{index};
    my $price = $pivot->{price};
    my $type  = $pivot->{type};
    my $color = _type_color($type);

    if (defined $pivot->{from_index} && defined $pivot->{from_price}
        && $pivot->{from_index} < $idx) {
        my $from_i = $pivot->{from_index};
        if ($idx >= $d_start && $from_i <= $d_end) {
            my $draw_start = $from_i < $d_start ? $d_start : $from_i;
            my $draw_end   = $idx > $d_end ? $d_end : $idx;
            if ($draw_start <= $draw_end) {
                my $span = $idx - $from_i;
                my $slope = ($price - $pivot->{from_price}) / $span;
                my $p1 = $pivot->{from_price} + $slope * ($draw_start - $from_i);
                my $p2 = $pivot->{from_price} + $slope * ($draw_end   - $from_i);
                $canvas->createLine(
                    $scale->index_to_center_x($draw_start), $scale->value_to_y($p1),
                    $scale->index_to_center_x($draw_end),   $scale->value_to_y($p2),
                    -fill => $color, -width => 1, -dash => [3, 3],
                    -tags => [ 'pmr_overlay', 'pmr_line', 'pmr_provisional', 'pmr_provisional_segment' ],
                );
            }
        }
    }

    if ($idx <= $d_end && $current_bar >= $d_start) {
        my $draw_start = $idx < $d_start ? $d_start : $idx;
        my $draw_end = $current_bar > $d_end ? $d_end : $current_bar;
        if ($draw_start <= $draw_end) {
            my $y = $scale->value_to_y($price);
            unless (_outside_y($scale, $y, 20)) {
                $canvas->createLine(
                    $scale->index_to_center_x($draw_start), $y,
                    $scale->index_to_center_x($draw_end),   $y,
                    -fill => $color, -width => 1, -dash => [2, 3],
                    -tags => [ 'pmr_overlay', 'pmr_line', 'pmr_provisional', 'pmr_provisional_level' ],
                );
            }
        }
    }

    return if $idx < $d_start || $idx > $d_end;
    my $x = $scale->index_to_center_x($idx);
    my $price_y = $scale->value_to_y($price);
    return if _outside_y($scale, $price_y, 30);
    my $cy = ($type // '') eq 'high' ? $price_y - 19 : $price_y + 19;
    if (defined $scale->{y_height}) {
        $cy = 10 if $cy < 10;
        $cy = $scale->{y_height} - 10 if $cy > $scale->{y_height} - 10;
    }
    $self->_draw_ghost($canvas, $x, $cy, $color, 'pmr_provisional');
}

sub _draw_ghost {
    my ($self, $canvas, $cx, $cy, $bg, $extra_tag) = @_;
    my @tags = ( 'pmr_overlay', 'pmr_label', 'pmr_ghost' );
    push @tags, $extra_tag if defined $extra_tag;

    $canvas->createRectangle(
        $cx - 9, $cy - 9, $cx + 9, $cy + 9,
        -fill => $bg, -outline => $bg, -tags => \@tags,
    );
    $canvas->createOval(
        $cx - 6, $cy - 7, $cx + 6, $cy + 5,
        -fill => '#ffffff', -outline => '#ffffff', -tags => \@tags,
    );
    $canvas->createPolygon(
        $cx - 6, $cy + 1,
        $cx - 6, $cy + 7,
        $cx - 3, $cy + 4,
        $cx,     $cy + 7,
        $cx + 3, $cy + 4,
        $cx + 6, $cy + 7,
        $cx + 6, $cy + 1,
        -fill => '#ffffff', -outline => '#ffffff', -tags => \@tags,
    );
    for my $eye_x ($cx - 2.4, $cx + 2.4) {
        $canvas->createOval(
            $eye_x - 1.1, $cy - 2.1, $eye_x + 1.1, $cy + 0.1,
            -fill => $COLOR_EYE, -outline => $COLOR_EYE, -tags => \@tags,
        );
    }
}

sub _render_segments {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $events) = @_;
    my %seen;
    my @ordered = sort {
        ($a->{index} // 0) <=> ($b->{index} // 0)
            || (($a->{confirmed_at} // 0) <=> ($b->{confirmed_at} // 0))
    } grep {
        my $key = join(':', $_->{type} // '', $_->{index} // '', $_->{price} // '');
        !$seen{$key}++;
    } @$events;
    return if @ordered < 2;

    for my $i (1 .. $#ordered) {
        my ($from, $to) = @ordered[$i - 1, $i];
        my ($from_i, $to_i) = ($from->{index}, $to->{index});
        next unless defined $from_i && defined $to_i && $to_i > $from_i;
        next if $to_i < $d_start || $from_i > $d_end || $from_i > $current_bar;

        my $draw_start = $from_i < $d_start ? $d_start : $from_i;
        my $draw_end   = $to_i > $d_end ? $d_end : $to_i;
        $draw_end = $current_bar if $draw_end > $current_bar;
        next if $draw_start > $draw_end;

        my $span = $to_i - $from_i;
        my $slope = ($to->{price} - $from->{price}) / $span;
        my $p1 = $from->{price} + $slope * ($draw_start - $from_i);
        my $p2 = $from->{price} + $slope * ($draw_end   - $from_i);
        my $x1 = $scale->index_to_center_x($draw_start);
        my $x2 = $scale->index_to_center_x($draw_end);
        my $y1 = $scale->value_to_y($p1);
        my $y2 = $scale->value_to_y($p2);
        next if _outside_same_side($scale, $y1, $y2, 40);

        my $contains_missed = (($from->{source} // '') eq 'missed')
            || (($to->{source} // '') eq 'missed');
        $canvas->createLine(
            $x1, $y1, $x2, $y2,
            -fill  => ($to->{type} // '') eq 'high' ? $COLOR_HIGH : $COLOR_LOW,
            -width => 1,
            ($contains_missed ? (-dash => [4, 3]) : ()),
            -tags  => [ 'pmr_overlay', 'pmr_line', 'pmr_segment' ],
        );
    }
}

sub _pivot_visible_at {
    my ($pivot, $current_bar) = @_;
    return 0 unless $pivot && defined $pivot->{index} && defined $pivot->{price};
    return 0 if $pivot->{index} > $current_bar;
    my $confirmed_at = $pivot->{confirmed_at} // $pivot->{confirmationIndex};
    return 0 unless defined $confirmed_at && $confirmed_at <= $current_bar;
    return 1;
}

sub _type_color {
    my ($type) = @_;
    return ($type // '') eq 'high' ? $COLOR_HIGH : $COLOR_LOW;
}

sub _outside_y {
    my ($scale, $y, $margin) = @_;
    return 0 unless defined $scale->{y_height};
    return $y < -$margin || $y > $scale->{y_height} + $margin;
}

sub _outside_same_side {
    my ($scale, $y1, $y2, $margin) = @_;
    return 0 unless defined $scale->{y_height};
    return 1 if $y1 < -$margin && $y2 < -$margin;
    return 1 if $y1 > $scale->{y_height} + $margin
             && $y2 > $scale->{y_height} + $margin;
    return 0;
}

1;
