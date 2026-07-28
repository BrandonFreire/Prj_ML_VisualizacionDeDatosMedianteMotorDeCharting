package Market::Overlays::Strategy_Builder;

use strict;
use warnings;


my $COLOR_ST_BULL  = '#26a69a';
my $COLOR_ST_BEAR  = '#ef5350';
my $COLOR_HT_BULL  = '#4caf50';
my $COLOR_HT_BEAR  = '#f44336';
my $COLOR_RF_UP    = '#66bb6a';
my $COLOR_RF_DOWN  = '#ef5350';
my $COLOR_SUPPLY   = '#ef5350';
my $COLOR_DEMAND   = '#26a69a';

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

    $canvas->delete('strategy_overlay');
    return unless $self->_visible('strategy_enabled', 1);

    $self->_render_range_filter($canvas, $d_start, $d_end, $scale, $current_bar)
        if $self->_visible('show_range_filter', 1);
    $self->_render_supply_demand($canvas, $d_start, $d_end, $scale, $current_bar)
        if $self->_visible('show_supply_demand', 1);
    $self->_render_supertrend($canvas, $d_start, $d_end, $scale, $current_bar)
        if $self->_visible('show_supertrend', 1);
    $self->_render_halftrend($canvas, $d_start, $d_end, $scale, $current_bar)
        if $self->_visible('show_halftrend', 1);
}

sub _render_supertrend {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    my $st = $self->{indicator}->get_supertrend() // [];
    return unless @$st;

    my @segments;
    my $cur_dir   = undef;
    my $seg_start = undef;

    for my $i ($d_start .. $d_end) {
        last if $i > $current_bar;
        next unless defined $st->[$i];
        my $dir = $st->[$i]{direction};

        if (!defined $cur_dir || $dir != $cur_dir) {
            if (defined $seg_start) {
                push @segments, { dir => $cur_dir, from => $seg_start, to => $i - 1 };
            }
            $seg_start = $i;
            $cur_dir   = $dir;
        }
    }
    my $last = $d_end < $current_bar ? $d_end : $current_bar;
    push @segments, { dir => $cur_dir, from => $seg_start, to => $last }
        if defined $seg_start;

    for my $seg (@segments) {
        my @coords;
        for my $i ($seg->{from} .. $seg->{to}) {
            next unless defined $st->[$i];
            my $x = $scale->index_to_center_x($i);
            my $y = $scale->value_to_y($st->[$i]{value});
            push @coords, $x, $y;
        }
        next if @coords < 4;

        my $color = $seg->{dir} == 1 ? $COLOR_ST_BULL : $COLOR_ST_BEAR;
        $canvas->createLine(@coords,
            -fill  => $color,
            -width => 2,
            -smooth => 0,
            -tags  => ['strategy_overlay', 'st_line'],
        );
    }
}

sub _render_halftrend {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    my $ht = $self->{indicator}->get_halftrend() // [];
    return unless @$ht;

    my @coords_line;
    for my $i ($d_start .. $d_end) {
        last if $i > $current_bar;
        next unless defined $ht->[$i];
        my $x = $scale->index_to_center_x($i);
        my $y = $scale->value_to_y($ht->[$i]{value});
        push @coords_line, $x, $y;
    }
    if (@coords_line >= 4) {
        my $last_vis = $d_end < $current_bar ? $d_end : $current_bar;
        my $clr = ($ht->[$last_vis]{trend} // 0) == 0 ? $COLOR_HT_BULL : $COLOR_HT_BEAR;
        $canvas->createLine(@coords_line,
            -fill  => $clr,
            -width => 2,
            -tags  => ['strategy_overlay', 'ht_line'],
        );
    }

    my @coords_hi;
    my @coords_lo;
    for my $i ($d_start .. $d_end) {
        last if $i > $current_bar;
        next unless defined $ht->[$i];
        my $x = $scale->index_to_center_x($i);
        push @coords_hi, $x, $scale->value_to_y($ht->[$i]{atr_high});
        push @coords_lo, $x, $scale->value_to_y($ht->[$i]{atr_low});
    }
    if (@coords_hi >= 4) {
        $canvas->createLine(@coords_hi,
            -fill => '#5c6370', -width => 1, -dash => [2, 3],
            -tags => ['strategy_overlay', 'ht_channel'],
        );
    }
    if (@coords_lo >= 4) {
        $canvas->createLine(@coords_lo,
            -fill => '#5c6370', -width => 1, -dash => [2, 3],
            -tags => ['strategy_overlay', 'ht_channel'],
        );
    }

    for my $i ($d_start .. $d_end) {
        last if $i > $current_bar;
        next unless defined $ht->[$i] && $ht->[$i]{flipped};
        my $x  = $scale->index_to_center_x($i);
        my $is_up = $ht->[$i]{trend} == 0;
        my $y  = $scale->value_to_y($ht->[$i]{value});
        my $arrow = $is_up ? "\x{25B2}" : "\x{25BC}";
        my $color = $is_up ? $COLOR_HT_BULL : $COLOR_HT_BEAR;
        my $yoff  = $is_up ? 12 : -12;
        $canvas->createText($x, $y + $yoff,
            -text   => $arrow,
            -fill   => $color,
            -font   => ['Helvetica', 10, 'bold'],
            -anchor => 'center',
            -tags   => ['strategy_overlay', 'ht_arrow'],
        );
    }
}

sub _render_range_filter {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    my $rf = $self->{indicator}->get_range_filter() // [];
    return unless @$rf;

    my $bar_w    = $scale->{x_width} / ($scale->{visible_bars} || 1);
    my $half_bar = $bar_w * 0.5;

    for my $i ($d_start .. $d_end) {
        last if $i > $current_bar;
        next unless defined $rf->[$i];
        my $x  = $scale->index_to_center_x($i);
        my $y1 = $scale->value_to_y($rf->[$i]{hi_band});
        my $y2 = $scale->value_to_y($rf->[$i]{lo_band});
        ($y1, $y2) = ($y2, $y1) if $y2 < $y1;

        my $color = $rf->[$i]{direction} == 1 ? $COLOR_RF_UP : $COLOR_RF_DOWN;
        $canvas->createRectangle(
            $x - $half_bar, $y1, $x + $half_bar, $y2,
            -fill    => $color,
            -outline => '',
            -stipple => 'gray12',
            -tags    => ['strategy_overlay', 'rf_band'],
        );
    }

    my @coords;
    for my $i ($d_start .. $d_end) {
        last if $i > $current_bar;
        next unless defined $rf->[$i];
        my $x = $scale->index_to_center_x($i);
        my $y = $scale->value_to_y($rf->[$i]{filter_value});
        push @coords, $x, $y;
    }
    if (@coords >= 4) {
        $canvas->createLine(@coords,
            -fill  => '#ab47bc',
            -width => 1.5,
            -tags  => ['strategy_overlay', 'rf_line'],
        );
    }

    $canvas->lower('rf_band', 'candles') if $canvas->find('withtag', 'candles');
}

sub _render_supply_demand {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    my $candles = $self->{indicator}->can('get_candles')
        ? $self->{indicator}->get_candles()
        : [];
    my $bar_w   = $scale->{x_width} / ($scale->{visible_bars} || 1);
    my $half_bar = $bar_w * 0.5;

    for my $type (qw(supply demand)) {
        my $zones = $type eq 'supply'
            ? ($self->{indicator}->get_supply_zones() // [])
            : ($self->{indicator}->get_demand_zones() // []);

        my $color = $type eq 'supply' ? $COLOR_SUPPLY : $COLOR_DEMAND;
        my $label = $type eq 'supply' ? 'S' : 'D';

        my @cands = grep {
            defined $_->{confirmed_at} && $_->{confirmed_at} <= $current_bar
        } @$zones;
        @cands = sort { ($b->{confirmed_at}//0) <=> ($a->{confirmed_at}//0) } @cands;
        @cands = @cands[0..14] if @cands > 15;
        @cands = sort { ($a->{index}//0) <=> ($b->{index}//0) } @cands;

        for my $zone (@cands) {
            next unless defined $zone->{top} && defined $zone->{bottom};
            my $start = $zone->{index};
            next unless defined $start;

            my $mitigated = 0;
            my $check_from = ($zone->{triggered_by} // $start) + 1;
            for my $j ($check_from .. ($current_bar < $#$candles ? $current_bar : $#$candles)) {
                my $c = $candles->[$j] // next;
                if ($type eq 'supply' && defined $c->{high} && $c->{high} >= $zone->{bottom}) {
                    $mitigated = $j; last;
                }
                if ($type eq 'demand' && defined $c->{low} && $c->{low} <= $zone->{top}) {
                    $mitigated = $j; last;
                }
            }
            next if $mitigated && $mitigated <= $current_bar;

            my $end_idx    = $current_bar;
            my $draw_start = $start < $d_start ? $d_start : $start;
            my $draw_end   = $end_idx > $d_end ? $d_end : $end_idx;
            next if $draw_start > $draw_end || $end_idx < $d_start || $start > $d_end;

            my $x1 = $scale->index_to_center_x($draw_start) - $half_bar;
            my $x2 = $scale->index_to_center_x($draw_end) + $half_bar;
            next if $x1 > $scale->{x_width} || $x2 < 0 || $x2 <= $x1;

            my $yt = $scale->value_to_y($zone->{top});
            my $yb = $scale->value_to_y($zone->{bottom});
            my ($y1, $y2) = $yt < $yb ? ($yt, $yb) : ($yb, $yt);

            $canvas->createRectangle($x1, $y1, $x2, $y2,
                -fill    => $color,
                -outline => $color,
                -stipple => 'gray25',
                -tags    => ['strategy_overlay', "sd_${type}"],
            );

            $canvas->createText($x1 + 3, ($y1 + $y2) / 2,
                -text   => $label,
                -fill   => $color,
                -font   => ['Helvetica', 7, 'bold'],
                -anchor => 'w',
                -tags   => ['strategy_overlay', 'strategy_label', "sd_${type}"],
            );
        }
    }

    $canvas->lower('sd_supply', 'candles') if $canvas->find('withtag', 'candles');
    $canvas->lower('sd_demand', 'candles') if $canvas->find('withtag', 'candles');
}

1;
