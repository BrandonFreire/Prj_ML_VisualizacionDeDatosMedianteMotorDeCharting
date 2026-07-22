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
        my $segments = $ind->can('get_internal_segments_until')
            ? $ind->get_internal_segments_until($current_bar)
            : $ind->get_internal_segments();
        $self->_render_segments(
            $canvas, $d_start, $d_end, $scale, $current_bar,
            $segments // [],
            undef, 2, 'zz_internal'
        );
    }

    # Obtener pivotes externos (necesarios para regresion y fibonacci aunque ZZ no se muestre)
    my $ext_pivots;
    if ( $ind->can('get_external_pivots') ) {
        $ext_pivots = $ind->can('get_external_pivots_until')
            ? $ind->get_external_pivots_until($current_bar)
            : $ind->get_external_pivots();
    }

    if ( $self->_visible('show_zz_external', 1) && $ind->can('get_external_segments') ) {
        my $segments = $ind->can('get_external_segments_until')
            ? $ind->get_external_segments_until($current_bar)
            : $ind->get_external_segments();
        $self->_render_segments(
            $canvas, $d_start, $d_end, $scale, $current_bar,
            $segments // [],
            $COLOR_EXTERNAL, 3, 'zz_external'
        );
        if ( $self->_visible('show_zz_hldv', 1) && $ext_pivots ) {
            $self->_render_hldv_labels(
                $canvas, $d_start, $d_end, $scale, $current_bar,
                $ext_pivots // []
            );
        }
    }

    # Canal de regresion automatico: funciona aunque ZZ externo no se muestre
    if ( $self->_visible('show_regression_auto', 0) && $ext_pivots ) {
        my $candles = $ind->can('get_candles') ? ($ind->get_candles() // []) : [];
        $self->_render_auto_regression(
            $canvas, $d_start, $d_end, $scale, $current_bar,
            $ext_pivots, $candles
        );
    }

    # Fibonacci automatico: requiere ZZ externo activo para que sea coherente
    if ( $self->_visible('show_zz_fibonacci', 0) && $ext_pivots && @$ext_pivots ) {
        $self->_render_fibonacci(
            $canvas, $d_start, $d_end, $scale, $current_bar,
            $ext_pivots
        );
    }
}

sub _render_auto_regression {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $pivots, $candles) = @_;
    return unless $pivots && @$pivots >= 2;

    my @pts = grep {
        defined $_->{index} && defined $_->{price} && $_->{index} <= $current_bar
    } @$pivots;
    return unless @pts >= 2;

    my $n = scalar @pts;
    my ($sum_x, $sum_y, $sum_xy, $sum_x2) = (0, 0, 0, 0);
    for my $p (@pts) {
        $sum_x  += $p->{index};
        $sum_y  += $p->{price};
        $sum_xy += $p->{index} * $p->{price};
        $sum_x2 += $p->{index} * $p->{index};
    }
    my $denom = $n * $sum_x2 - $sum_x * $sum_x;
    return if $denom == 0;
    my $slope     = ($n * $sum_xy - $sum_x * $sum_y) / $denom;
    my $intercept = ($sum_y - $slope * $sum_x) / $n;

    my $sum_res2 = 0;
    for my $p (@pts) {
        my $res = $p->{price} - ($slope * $p->{index} + $intercept);
        $sum_res2 += $res * $res;
    }
    my $std_dev = $n > 1 ? sqrt($sum_res2 / $n) : 0;

    my $x_from = $pts[0]{index};
    my $x_to   = $current_bar;
    return if $x_from > $d_end || $x_to < $d_start;

    my $draw_from = $x_from < $d_start ? $d_start : $x_from;
    my $draw_to   = $x_to   > $d_end   ? $d_end   : $x_to;
    return if $draw_from > $draw_to;

    my $px1 = $scale->index_to_center_x($draw_from);
    my $px2 = $scale->index_to_center_x($draw_to);
    return if $px1 > $scale->{x_width} || $px2 < 0;

    my $reg = sub { $slope * $_[0] + $intercept };
    for my $band (
        [ $std_dev,  '#26a69a', 1, [4, 3] ],
        [ 0,         $COLOR_EXTERNAL, 2, []    ],
        [ -$std_dev, '#ef5350', 1, [4, 3] ],
    ) {
        my ($offset, $color, $width, $dash) = @$band;
        my $y1 = $scale->value_to_y($reg->($draw_from) + $offset);
        my $y2 = $scale->value_to_y($reg->($draw_to)   + $offset);
        my @opts = (
            -fill  => $color,
            -width => $width,
            -tags  => ['zz_overlay', 'zz_regression'],
        );
        push @opts, (-dash => $dash) if @$dash;
        $canvas->createLine($px1, $y1, $px2, $y2, @opts);
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

sub _render_hldv_labels {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $pivots) = @_;
    return unless $pivots && @$pivots;

    my ($last_high, $last_low);
    for my $p (@$pivots) {
        my ($idx, $price, $type) = @{$p}{qw(index price type)};
        next unless defined $idx && defined $price && defined $type;
        next if $idx > $current_bar;
        next if ($p->{confirmed_at} // $idx) > $current_bar;

        my $label = $p->{label};
        if ($type eq 'high') {
            $label    //= (defined $last_high && $price > $last_high) ? 'HH' : 'LH';
            $last_high  = $price;
        } else {
            $label    //= (defined $last_low  && $price > $last_low)  ? 'HL' : 'LL';
            $last_low   = $price;
        }
        next unless $idx >= $d_start && $idx <= $d_end;

        my $x    = $scale->index_to_center_x($idx);
        my $y    = $scale->value_to_y($price);
        my $yoff = $type eq 'high' ? -14 : 14;

        $canvas->createText($x, $y + $yoff,
            -text   => $label,
            -fill   => $COLOR_EXTERNAL,
            -font   => ['Helvetica', 8, 'bold'],
            -anchor => 'center',
            -tags   => ['zz_overlay', 'zz_hldv', lc($label)],
        );
    }
}

sub _render_fibonacci {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $pivots) = @_;

    # Toma el ultimo swing grande: busca el ultimo high y ultimo low confirmados
    my ($last_high, $last_low);
    for my $p (reverse @$pivots) {
        next if ($p->{confirmed_at} // $p->{index}) > $current_bar;
        next if $p->{index} > $current_bar;
        if ( !defined $last_high && ($p->{type} // '') eq 'high' ) {
            $last_high = $p;
        }
        if ( !defined $last_low && ($p->{type} // '') eq 'low' ) {
            $last_low = $p;
        }
        last if defined $last_high && defined $last_low;
    }
    return unless defined $last_high && defined $last_low;

    # El swing es del pivote mas antiguo al mas reciente
    my ($swing_start, $swing_end) =
        $last_high->{index} < $last_low->{index}
        ? ($last_high, $last_low)
        : ($last_low,  $last_high);

    my $price_high = $last_high->{price};
    my $price_low  = $last_low->{price};
    my $range      = $price_high - $price_low;
    return if $range == 0;

    # Niveles Fibonacci (retroceso: 0 = extremo inicial, 1 = extremo opuesto)
    my @levels = (
        [ 0,     '#787b86', '0' ],
        [ 0.236, '#f7c948', '0.236' ],
        [ 0.382, '#ef5350', '0.382' ],
        [ 0.5,   '#ffffff', '0.5' ],
        [ 0.618, '#26a69a', '0.618' ],
        [ 0.786, '#ab47bc', '0.786' ],
        [ 1,     '#787b86', '1' ],
    );

    # Precio actual (ultima vela visible)
    my $candles = $self->{indicator}->can('get_candles')
                ? ($self->{indicator}->get_candles() // [])
                : [];
    my $cur_price;
    if ( @$candles && $current_bar >= 0 && $current_bar < scalar @$candles ) {
        my $c = $candles->[$current_bar];
        $cur_price = ref($c) eq 'HASH' ? $c->{close} : (ref($c) eq 'ARRAY' ? $c->[4] : undef);
    }

    my $x_from = $scale->index_to_center_x( $swing_start->{index} < $d_start ? $d_start : $swing_start->{index} );
    my $x_to   = $scale->index_to_center_x( $d_end );

    for my $lv (@levels) {
        my ($ratio, $color, $label_txt) = @$lv;
        # Si swing sube (high > low y high es el final), retroceso desde high hacia low
        # Si swing baja (low > high y low es el final), retroceso desde low hacia high
        my $price;
        if ( $last_high->{index} > $last_low->{index} ) {
            # Swing bajista (high primero, low despues) => retroceso sube desde low
            $price = $price_low + $range * (1 - $ratio);
        } else {
            # Swing alcista (low primero, high despues) => retroceso baja desde high
            $price = $price_high - $range * $ratio;
        }

        my $y = $scale->value_to_y($price);
        $canvas->createLine(
            $x_from, $y, $x_to, $y,
            -fill  => $color,
            -width => 1,
            -dash  => [4, 3],
            -tags  => ['zz_overlay', 'zz_fibonacci'],
        );

        # Etiqueta con nivel y precio
        my $price_str = sprintf("%.5g", $price);
        my $lbl = "$label_txt  $price_str";

        # Marca el nivel donde esta el precio actual
        if ( defined $cur_price ) {
            my $band = $range * 0.005;
            if ( abs($cur_price - $price) <= $band ) {
                $lbl = ">> $lbl <<";
                $color = '#ffffff';
            }
        }

        $canvas->createText(
            $x_to - 4, $y - 7,
            -text   => $lbl,
            -fill   => $color,
            -font   => ['Helvetica', 7],
            -anchor => 'e',
            -tags   => ['zz_overlay', 'zz_fibonacci'],
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
