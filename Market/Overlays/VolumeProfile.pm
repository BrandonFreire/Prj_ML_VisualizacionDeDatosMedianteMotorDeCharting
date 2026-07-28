package Market::Overlays::VolumeProfile;

use strict;
use warnings;


my $COLOR_POC   = '#f6c90e';
my $COLOR_VAH   = '#26a69a';
my $COLOR_VAL   = '#ef5350';
my $COLOR_HIST  = '#4a5568';
my $MAX_BAR_PX  = 80;

sub new {
    my ($class, %args) = @_;
    return bless {
        indicator  => $args{indicator},
        visibility => $args{visibility},
        max_bar_px => $args{max_bar_px} // $MAX_BAR_PX,
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

    $canvas->delete('vp_overlay');
    return unless $self->_visible('vp_enabled', 1);

    my $manual_anchors = $ind->{_manual_anchors} // [];
    return unless @$manual_anchors && defined $manual_anchors->[0]{start};

    my $profiles = $ind->can('get_profiles_at')
        ? ($ind->get_profiles_at($current_bar) // [])
        : ($ind->get_profiles() // []);
    $profiles = [ grep { ($_->{source} // '') eq 'manual' } @$profiles ];
    return unless @$profiles;

    for my $profile (@$profiles) {
        next unless $profile;
        my $p_start = $profile->{start_idx} // next;
        my $p_end   = $profile->{end_idx}   // next;
        next if $p_start > $d_end || $p_end < $d_start;
        next if $p_start > $current_bar;

        $self->_render_histogram($canvas, $d_start, $d_end, $scale, $current_bar, $profile);
        $self->_render_levels($canvas, $d_start, $d_end, $scale, $current_bar, $profile);
    }

    $canvas->lower('vp_hist', 'candles') if $canvas->find('withtag', 'candles');
}


my $COLOR_UP_IN_VA   = '#26a69a';
my $COLOR_DOWN_IN_VA = '#ef5350';
my $COLOR_UP_OUT     = '#1a6b63';
my $COLOR_DOWN_OUT   = '#8b2d2d';
my $COLOR_POC_FILL   = '#f6c90e';

sub _render_histogram {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $profile) = @_;
    my $bins    = $profile->{bins} // [];
    my $max_vol = $profile->{max_vol};
    return unless @$bins && $max_vol > 0;

    my $max_bar  = $self->{max_bar_px};
    my $p_start  = $profile->{start_idx};
    my $p_end    = $profile->{end_idx};
    my $draw_end = $p_end > $current_bar ? $current_bar : $p_end;
    $draw_end    = $d_end if $draw_end > $d_end;

    my $poc_price = $profile->{poc} // 0;
    my $vah_price = $profile->{vah} // 1e30;
    my $val_price = $profile->{val} // -1e30;

    my $x_anchor = $scale->index_to_center_x($draw_end);

    for my $bin (@$bins) {
        next unless $bin->{volume} > 0;
        my $y1 = $scale->value_to_y($bin->{price_high});
        my $y2 = $scale->value_to_y($bin->{price_low});
        ($y1, $y2) = ($y2, $y1) if $y2 < $y1;

        next if defined $scale->{y_height} && ($y2 < 0 || $y1 > $scale->{y_height});

        my $bar_w = ($bin->{volume} / $max_vol) * $max_bar;
        $bar_w = 2 if $bar_w < 2;

        my $is_poc = abs($bin->{price} - $poc_price) <
                     abs(($bin->{price_high} - $bin->{price_low}) / 2 + 0.001);

        my $in_va = ($bin->{price} >= $val_price && $bin->{price} <= $vah_price) ? 1 : 0;

        my $up_vol   = $bin->{up_volume}   // 0;
        my $down_vol = $bin->{down_volume} // 0;
        my $bin_total = $up_vol + $down_vol;
        $bin_total = $bin->{volume} if $bin_total <= 0;

        my $down_frac = $bin_total > 0 ? ($down_vol / $bin_total) : 0.5;
        my $up_frac   = 1 - $down_frac;

        my $down_w = $bar_w * $down_frac;
        my $up_w   = $bar_w * $up_frac;

        my ($color_down, $color_up);
        if ($is_poc) {
            $color_down = $COLOR_POC_FILL;
            $color_up   = $COLOR_POC_FILL;
        } elsif ($in_va) {
            $color_down = $COLOR_DOWN_IN_VA;
            $color_up   = $COLOR_UP_IN_VA;
        } else {
            $color_down = $COLOR_DOWN_OUT;
            $color_up   = $COLOR_UP_OUT;
        }

        my $x_start = $x_anchor - $bar_w;

        if ($down_w >= 1) {
            $canvas->createRectangle($x_start, $y1, $x_start + $down_w, $y2,
                -fill    => $color_down,
                -outline => '',
                -tags    => ['vp_overlay', 'vp_hist'],
            );
        }

        if ($up_w >= 1) {
            $canvas->createRectangle($x_start + $down_w, $y1, $x_anchor, $y2,
                -fill    => $color_up,
                -outline => '',
                -tags    => ['vp_overlay', 'vp_hist'],
            );
        }
    }
}

sub _render_levels {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar, $profile) = @_;
    my $p_start = $profile->{start_idx};
    my $p_end   = $profile->{end_idx};

    my $draw_start = $p_start < $d_start ? $d_start : $p_start;
    my $draw_end   = $p_end   > $d_end   ? $d_end   : $p_end;
    $draw_end = $current_bar if $draw_end > $current_bar;
    return if $draw_start > $draw_end;

    my $x1 = $scale->index_to_center_x($draw_start);
    my $x2 = $scale->index_to_center_x($draw_end);
    return if $x1 > $scale->{x_width} || $x2 < 0 || $x1 >= $x2;

    if (defined $profile->{poc} && $self->_visible('show_vp_poc', 1)) {
        my $y = $scale->value_to_y($profile->{poc});
        if (!defined $scale->{y_height} || ($y >= -20 && $y <= $scale->{y_height} + 20)) {
            $canvas->createLine($x1, $y, $x2, $y,
                -fill  => $COLOR_POC,
                -width => 1.8,
                -dash  => [6, 3],
                -tags  => ['vp_overlay', 'vp_poc'],
            );
            $canvas->createText($x2 - 4, $y - 8,
                -text   => 'POC',
                -fill   => $COLOR_POC,
                -font   => ['Helvetica', 8, 'bold'],
                -anchor => 'e',
                -tags   => ['vp_overlay', 'vp_label'],
            );
        }
    }

    if (defined $profile->{vah} && $self->_visible('show_vp_vah', 1)) {
        my $y = $scale->value_to_y($profile->{vah});
        if (!defined $scale->{y_height} || ($y >= -20 && $y <= $scale->{y_height} + 20)) {
            $canvas->createLine($x1, $y, $x2, $y,
                -fill  => $COLOR_VAH,
                -width => 1.2,
                -dash  => [4, 4],
                -tags  => ['vp_overlay', 'vp_vah'],
            );
            $canvas->createText($x2 - 4, $y - 8,
                -text   => 'VAH',
                -fill   => $COLOR_VAH,
                -font   => ['Helvetica', 7, 'bold'],
                -anchor => 'e',
                -tags   => ['vp_overlay', 'vp_label'],
            );
        }
    }

    if (defined $profile->{val} && $self->_visible('show_vp_val', 1)) {
        my $y = $scale->value_to_y($profile->{val});
        if (!defined $scale->{y_height} || ($y >= -20 && $y <= $scale->{y_height} + 20)) {
            $canvas->createLine($x1, $y, $x2, $y,
                -fill  => $COLOR_VAL,
                -width => 1.2,
                -dash  => [4, 4],
                -tags  => ['vp_overlay', 'vp_val'],
            );
            $canvas->createText($x2 - 4, $y + 8,
                -text   => 'VAL',
                -fill   => $COLOR_VAL,
                -font   => ['Helvetica', 7, 'bold'],
                -anchor => 'e',
                -tags   => ['vp_overlay', 'vp_label'],
            );
        }
    }
}

1;
