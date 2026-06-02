package Market::ChartEngine;

use strict;
use warnings;
use POSIX qw(strftime);
use Market::Panels::Scales;
use Market::Panels::PricePanel;
use Market::Panels::ATRPanel;

# Orchestrates the complete rendering pipeline.
# Coordinates panels, scales, and user events.
# No global variables; all state is encapsulated here.

my $TIME_AXIS_H = 30;   # pixels reserved at bottom of price canvas for time axis

sub new {
    my ($class, %args) = @_;
    my $self = {
        market             => $args{market},
        indicators         => $args{indicators},
        price_canvas       => $args{price_canvas},
        price_scale_canvas => $args{price_scale_canvas},
        atr_canvas         => $args{atr_canvas},
        atr_scale_canvas   => $args{atr_scale_canvas},

        visible_bars   => $args{visible_bars} // 100,
        offset         => 0,
        follow_last    => 1,
        auto_follow    => 1,
        manual_scroll  => 0,
        y_auto         => 1,
        y_min_manual   => 0,
        y_max_manual   => 1,

        crosshair_x        => undef,
        crosshair_y_price  => undef,
        crosshair_y_atr    => undef,
        crosshair_info     => undef,
        _last_mouse_x      => undef,
        pending_render => 0,

        _drag_start_x      => undef,
        _drag_start_offset => 0,
        _render_state      => undef,

        price_panel => undef,
        atr_panel   => undef,
        price_scale => undef,
        atr_scale   => undef,
    };
    bless $self, $class;

    $self->{price_panel} = Market::Panels::PricePanel->new(
        canvas       => $self->{price_canvas},
        scale_canvas => $self->{price_scale_canvas},
    );
    $self->{atr_panel} = Market::Panels::ATRPanel->new(
        canvas       => $self->{atr_canvas},
        scale_canvas => $self->{atr_scale_canvas},
    );

    return $self;
}

# Calculates which candle indices are currently visible
sub compute_window {
    my ($self) = @_;
    my $last  = $self->{market}->last_index();
    return (0, -1) if $last < 0;

    $self->{offset} = 0     if $self->{offset} < 0;
    $self->{offset} = $last if $self->{offset} > $last;

    my $end   = $last - $self->{offset};
    $end = $last if $end > $last;
    $end = 0     if $end < 0;

    my $start = $end - $self->{visible_bars} + 1;
    $start = 0 if $start < 0;

    return ($start, $end);
}

sub round {
    my ($self, $v) = @_;
    return int( $v + 0.5 );
}

# Schedule a deferred render (~1 frame delay) to avoid redundant redraws
sub request_render {
    my ($self) = @_;
    return if $self->{pending_render};
    $self->{pending_render} = 1;
    $self->{price_canvas}->after( 16, sub { $self->render() } );
}

# Main entry point: builds scales, then dispatches to full or incremental render
sub render {
    my ($self) = @_;
    $self->{pending_render} = 0;

    # Fix scrollregion so Button-4/5 cannot scroll the viewport
    for my $cv ( $self->{price_canvas}, $self->{atr_canvas} ) {
        my $w = $cv->width()  || 1;
        my $h = $cv->height() || 1;
        $cv->configure( -scrollregion => [ 0, 0, $w, $h ] );
    }

    my ($start, $end) = $self->compute_window();
    my $data_slice = $self->{market}->get_slice($start, $end);
    return unless @$data_slice;

    my $n_visible = scalar @$data_slice;
    my $pw  = $self->{price_canvas}->width()        || 900;
    my $ph  = $self->{price_canvas}->height()       || 500;
    my $aw  = $self->{atr_canvas}->width()          || 900;
    my $ah  = $self->{atr_canvas}->height()         || 150;

    # Build price scale
    my $price_scale = Market::Panels::Scales->new(
        x_left       => 0,
        x_width      => $pw,
        start_index  => $start,
        visible_bars => $n_visible,
        y_top        => 0,
        y_height     => $ph - $TIME_AXIS_H,
        y_min        => 0,
        y_max        => 1,
    );

    if ( $self->{y_auto} ) {
        my ( $p_min, $p_max ) = $self->{price_panel}->get_y_range($data_slice);
        $price_scale->{y_min} = $p_min;
        $price_scale->{y_max} = $p_max;
    }
    else {
        $price_scale->{y_min} = $self->{y_min_manual};
        $price_scale->{y_max} = $self->{y_max_manual};
    }
    $self->{price_scale} = $price_scale;

    # Build ATR scale
    my $atr_slice = $self->{indicators}->slice_array( 'ATR', $start, $end );

    my $atr_scale = Market::Panels::Scales->new(
        x_left       => 0,
        x_width      => $aw,
        start_index  => $start,
        visible_bars => $n_visible,
        y_top        => 0,
        y_height     => $ah,
        y_min        => 0,
        y_max        => 1,
    );
    my ( $a_min, $a_max ) = $self->{atr_panel}->get_y_range($atr_slice);
    $atr_scale->{y_min} = $a_min;
    $atr_scale->{y_max} = $a_max;
    $self->{atr_scale} = $atr_scale;

    # Dispatch to incremental or full render
    my $rs = $self->{_render_state};
    if ( $rs && $self->_can_incremental( $rs, $start, $end, $price_scale, $n_visible, $pw, $ph ) ) {
        $self->_incremental_pan( $start, $end, $data_slice, $price_scale, $atr_slice, $atr_scale, $rs );
    }
    else {
        $self->_full_render( $start, $end, $data_slice, $price_scale, $atr_slice, $atr_scale );
    }

    # Save state for next incremental check
    $self->{_render_state} = {
        start        => $start,
        end          => $end,
        y_min        => $price_scale->{y_min},
        y_max        => $price_scale->{y_max},
        a_min        => $atr_scale->{y_min},
        a_max        => $atr_scale->{y_max},
        visible_bars => $n_visible,
        pw           => $pw,
        ph           => $ph,
    };

    if ( defined $self->{crosshair_x} ) {
        $self->_update_crosshair_info();
        $self->_draw_crosshair_all();
    }
}

# Returns true when an incremental pan is safe (no Y rescale, no zoom, no resize)
sub _can_incremental {
    my ($self, $rs, $start, $end, $pscale, $n_visible, $pw, $ph) = @_;

    # Full redraw keeps candles, ATR and time labels synchronized while pan/zoom
    # behavior is being corrected. Incremental pan can be re-enabled after it
    # validates both price and ATR scales plus time-axis state.
    return 0;

    return 0 if $rs->{pw} != $pw || $rs->{ph} != $ph;
    return 0 if $rs->{visible_bars} != $n_visible;

    my $delta = abs( $start - $rs->{start} );
    return 0 if $delta == 0;
    return 0 if $delta >= $n_visible;

    # Reject if Y range shifted by more than 1% (candle Y-positions would be wrong)
    my $p_range = $rs->{y_max} - $rs->{y_min};
    return 0 if $p_range <= 0;
    my $p_diff = abs( $pscale->{y_max} - $rs->{y_max} )
               + abs( $pscale->{y_min} - $rs->{y_min} );
    return 0 if $p_diff > $p_range * 0.01;

    return 1;
}

# Complete redraw of all panels and scales
sub _full_render {
    my ($self, $start, $end, $data_slice, $pscale, $atr_slice, $ascale) = @_;

    my $pc  = $self->{price_canvas};
    my $psc = $self->{price_scale_canvas};
    my $ac  = $self->{atr_canvas};
    my $asc = $self->{atr_scale_canvas};

    # --- Price panel ---
    $pc->delete('all');
    $self->{price_panel}->set_scale($pscale);
    $self->{price_panel}->render( $pc, $data_slice, $pscale );
    my $ts = $self->compute_intraday_labels( $start, $end, $pscale );
    $self->{price_panel}->draw_time_axis( $pc, $ts );
    $self->{price_panel}->_init_crosshair_objects();

    # --- Price scale (must come after candles so lastprice draws on ready canvas) ---
    $psc->delete('all');
    $pscale->_draw_y_scale($psc);
    $self->{price_panel}->render_last_visible_price($pc);

    # --- ATR panel ---
    $ac->delete('all');
    $self->{atr_panel}->set_scale($ascale);
    $self->{atr_panel}->render( $ac, $atr_slice, $ascale );
    $self->{atr_panel}->_init_crosshair();

    # --- ATR scale ---
    $asc->delete('all');
    $ascale->_draw_y_scale($asc);
    $self->{atr_panel}->render_last_visible_value($ac);
}

# O(1) horizontal pan: move existing candles, add/delete only the edge bars
sub _incremental_pan {
    my ($self, $start, $end, $data_slice, $pscale, $atr_slice, $ascale, $rs) = @_;

    my $delta = $start - $rs->{start};
    my $bar_w = $pscale->{x_width} / ( $pscale->{visible_bars} || 1 );
    my $dx    = -$delta * $bar_w;

    my $pc  = $self->{price_canvas};
    my $psc = $self->{price_scale_canvas};
    my $ac  = $self->{atr_canvas};
    my $asc = $self->{atr_scale_canvas};

    $self->{price_panel}->set_scale($pscale);
    $self->{atr_panel}->set_scale($ascale);

    # --- Shift all candles O(1) ---
    $pc->move( 'candles', $dx, 0 );

    if ( $delta > 0 ) {
        # Panned left (newer data visible on right)
        $pc->delete("ci_$_") for $rs->{start} .. $start - 1;
        for my $i ( 0 .. $#$data_slice ) {
            my $ix = $start + $i;
            $self->{price_panel}->render_candle( $pc, $data_slice->[$i], $ix, $pscale )
                if $ix > $rs->{end};
        }
    }
    else {
        # Panned right (older data visible on left)
        $pc->delete("ci_$_") for $end + 1 .. $rs->{end};
        for my $i ( 0 .. $#$data_slice ) {
            my $ix = $start + $i;
            $self->{price_panel}->render_candle( $pc, $data_slice->[$i], $ix, $pscale )
                if $ix < $rs->{start};
        }
    }

    # Update last candle info for render_last_visible_price
    my $last = $data_slice->[-1];
    $self->{price_panel}{_last_close} = $last->{close};
    $self->{price_panel}{_last_open}  = $last->{open};

    # --- Redraw price grid ---
    $pc->delete('grid');
    for my $v ( $pscale->get_nice_levels() ) {
        my $y = $pscale->value_to_y($v);
        next if $y < 0 || $y > $pscale->{y_height};
        $pc->createLine( 0, $y, $pscale->{x_width}, $y,
            -fill => '#1e2130', -tags => ['grid'] );
    }
    $pc->lower( 'grid', 'candles' ) if $pc->find( 'withtag', 'candles' );

    # --- Redraw time axis ---
    $pc->delete('timeaxis');
    my $ts = $self->compute_intraday_labels( $start, $end, $pscale );
    $self->{price_panel}->draw_time_axis( $pc, $ts );

    # --- Redraw last price label ---
    $pc->delete('lastprice');
    $psc->delete('all');
    $pscale->_draw_y_scale($psc);
    $self->{price_panel}->render_last_visible_price($pc);

    # --- Redraw ATR (full, fast) ---
    $ac->delete('grid');
    $ac->delete('atr');
    $self->{atr_panel}->render( $ac, $atr_slice, $ascale );
    for my $i ( reverse 0 .. $#$atr_slice ) {
        if ( defined $atr_slice->[$i] ) {
            $self->{atr_panel}{_last_atr} = $atr_slice->[$i];
            last;
        }
    }

    # --- Redraw ATR scale + last ATR label ---
    $ac->delete('lastatr');
    $asc->delete('all');
    $ascale->_draw_y_scale($asc);
    $self->{atr_panel}->render_last_visible_value($ac);

    # Keep crosshair on top
    $pc->raise('crosshair');
    $ac->raise('crosshair');
}

# Bind all user input events
sub bind_events {
    my ($self) = @_;
    $self->_bind_all_canvas( $self->{price_canvas} );
    $self->_bind_all_canvas( $self->{atr_canvas} );

    # Vertical drag on price scale canvas (manual Y zoom)
    $self->{price_scale_canvas}->bind( '<ButtonPress-1>', sub {
        my $e = $self->{price_scale_canvas}->XEvent();
        $self->{_vy_drag_start} = $e->y;
        $self->{_vy_min_start}  = $self->{price_scale}{y_min} // 0;
        $self->{_vy_max_start}  = $self->{price_scale}{y_max} // 1;
    });
    $self->{price_scale_canvas}->bind( '<B1-Motion>', sub {
        my $e  = $self->{price_scale_canvas}->XEvent();
        $self->_vertical_drag( $e->y - ( $self->{_vy_drag_start} // $e->y ) );
        $self->{_vy_drag_start} = $e->y;
    });
}

sub _bind_all_canvas {
    my ($self, $c) = @_;
    $c->bind( '<Button-4>', sub {
        my $e = $c->XEvent();
        $self->zoom( -1, $e->x );
    });
    $c->bind( '<Button-5>', sub {
        my $e = $c->XEvent();
        $self->zoom( 1, $e->x );
    });
    $c->bind( '<MouseWheel>', sub {
        my $e = $c->XEvent();
        $self->zoom( $e->Delta > 0 ? -1 : 1, $e->x );
        $c->xviewMoveto(0); $c->yviewMoveto(0);
    });

    $c->bind( '<Motion>', sub {
        my $e = $c->XEvent();
        $self->_on_mouse_move( $e, $c );
    });
    $c->bind( '<Leave>', sub {
        $self->_hide_crosshair();
    });
}

# --- Public pan methods (called from market.pl) ---

sub drag_start {
    my ($self, $global_x) = @_;
    $self->{_drag_start_x}      = $global_x;
    $self->{_drag_start_offset} = $self->{offset};
    $self->_set_manual_scroll();
}

sub drag_end {
    my ($self) = @_;
    $self->{_drag_start_x} = undef;
    $self->_sync_follow_state();
}

sub drag_move {
    my ($self, $global_x) = @_;
    return unless defined $self->{_drag_start_x};

    my $dx    = $global_x - $self->{_drag_start_x};
    my $bar_w = ( $self->{price_canvas}->width() || 900 ) / ( $self->{visible_bars} || 100 );
    $bar_w    = 0.5 if $bar_w < 0.5;

    # TradingView-style grab: dragging right reveals older candles; dragging
    # left moves back toward the latest candle.
    my $new_off = $self->{_drag_start_offset} + int( $dx / $bar_w );
    $new_off = $self->_clamp_offset($new_off);

    if ( $new_off != $self->{offset} ) {
        $self->{offset}      = $new_off;
        $self->_sync_follow_state();
        $self->{_render_state} = undef;
        $self->render();
    }
}

# delta < 0 = zoom in  (fewer visible bars, wider bars)
# delta > 0 = zoom out (more visible bars, overview)
sub zoom {
    my ($self, $delta, $mouse_x) = @_;
    $mouse_x = $self->{_last_mouse_x} unless defined $mouse_x;

    my ($old_start, $old_end) = $self->compute_window();
    return if $old_end < $old_start;

    my $old_bars = $self->{visible_bars};
    my $factor   = $delta > 0 ? 1.4 : 0.65;
    my $new_bars = int( $old_bars * $factor + 0.5 );
    $new_bars = 5    if $new_bars < 5;
    $new_bars = 5000 if $new_bars > 5000;

    return if $new_bars == $old_bars;

    my $last  = $self->{market}->last_index();
    my $width = $self->{price_canvas}->width() || 900;
    my $has_mouse = defined $mouse_x && $mouse_x >= 0 && $mouse_x <= $width;

    $self->{visible_bars} = $new_bars;

    if ( $has_mouse ) {
        my $old_visible = $old_end - $old_start + 1;
        $old_visible = $old_bars if $old_visible <= 0;
        my $old_bar_w = $width / ( $old_visible || 1 );
        my $ratio     = $width > 0 ? $mouse_x / $width : 0.5;

        my $pivot_index = $old_start + ( $mouse_x / ( $old_bar_w || 1 ) ) - 0.5;
        $pivot_index = $old_start if $pivot_index < $old_start;
        $pivot_index = $old_end   if $pivot_index > $old_end;

        my $new_start = $pivot_index + 0.5 - $ratio * $new_bars;
        my $new_end   = int( $new_start + $new_bars - 1 + 0.5 );
        $self->{offset} = $self->_clamp_offset( $last - $new_end );
    }
    elsif ( $self->{follow_last} ) {
        $self->{offset} = 0;
    }
    else {
        my $pivot_index = ( $old_start + $old_end ) / 2;
        my $new_start   = $pivot_index + 0.5 - 0.5 * $new_bars;
        my $new_end     = int( $new_start + $new_bars - 1 + 0.5 );
        $self->{offset} = $self->_clamp_offset( $last - $new_end );
    }

    $self->_sync_follow_state();
    $self->{_render_state} = undef;    # force full render after zoom
    my $tf = $self->{market}{current_tf};
    $self->{price_canvas}->toplevel->title("Market Chart | ${tf}m  [velas: $new_bars]");
    $self->request_render();
}

sub _horizontal_zoom { my ($self, $delta) = @_; $self->zoom($delta) }

sub _vertical_drag {
    my ($self, $dy) = @_;
    return unless defined $self->{price_scale};

    my $scale  = $self->{price_scale};
    my $range  = $scale->{y_max} - $scale->{y_min};
    my $factor = 1 + $dy / ( $scale->{y_height} || 400 );
    $factor = 0.1  if $factor < 0.1;
    $factor = 10.0 if $factor > 10.0;

    my $mid      = ( $scale->{y_max} + $scale->{y_min} ) / 2;
    my $new_half = ( $range / 2 ) * $factor;

    $self->{y_auto}        = 0;
    $self->{y_min_manual}  = $mid - $new_half;
    $self->{y_max_manual}  = $mid + $new_half;
    $self->{_render_state} = undef;
    $self->request_render();
}

sub _vertical_zoom {
    my ($self, $factor) = @_;
    return unless defined $self->{price_scale};
    my $scale = $self->{price_scale};
    my $mid   = ( $scale->{y_max} + $scale->{y_min} ) / 2;
    my $half  = ( $scale->{y_max} - $scale->{y_min} ) / 2 * $factor;
    $self->{y_auto}        = 0;
    $self->{y_min_manual}  = $mid - $half;
    $self->{y_max_manual}  = $mid + $half;
    $self->{_render_state} = undef;
    $self->request_render();
}

sub _on_mouse_move {
    my ($self, $event, $canvas) = @_;
    $self->{crosshair_x} = $event->x;
    $self->{_last_mouse_x} = $event->x;

    if ( defined $canvas && "$canvas" eq "$self->{atr_canvas}" ) {
        $self->{crosshair_y_price} = undef;
        $self->{crosshair_y_atr}   = $event->y;
    }
    else {
        $self->{crosshair_y_price} = $event->y;
        $self->{crosshair_y_atr}   = undef;
    }

    $self->_update_crosshair_info();
    $self->_draw_crosshair_all();
}

sub _draw_crosshair_all {
    my ($self) = @_;
    return unless defined $self->{crosshair_x};

    my $info = $self->{crosshair_info};
    my $x    = $info && defined $info->{x} ? $info->{x} : $self->{crosshair_x};

    $self->{price_panel}->draw_crosshair( $x, $self->{crosshair_y_price}, $info );
    $self->{atr_panel}->draw_crosshair(   $x, $self->{crosshair_y_atr},   $info );
}

sub _hide_crosshair {
    my ($self) = @_;
    $self->{crosshair_x}       = undef;
    $self->{crosshair_y_price} = undef;
    $self->{crosshair_y_atr}   = undef;
    $self->{crosshair_info}    = undef;
    $self->{_last_mouse_x}     = undef;
    $self->{price_panel}->hide_crosshair();
    $self->{atr_panel}->hide_crosshair();
}

sub _update_crosshair_info {
    my ($self) = @_;
    my $scale = $self->{price_scale};
    return $self->{crosshair_info} = undef unless $scale && defined $self->{crosshair_x};

    my $index = $scale->x_to_index( $self->{crosshair_x} );
    my ($start, $end) = $self->compute_window();
    return $self->{crosshair_info} = undef if $index < $start || $index > $end;

    my $candle = $self->{market}->get_candle($index);
    return $self->{crosshair_info} = undef unless $candle;

    my $atr;
    my $indicator = $self->{indicators}->get('ATR');
    if ($indicator) {
        my $values = $indicator->get_values();
        $atr = $values->[$index] if defined $values && $index <= $#$values;
    }

    my $time_label = strftime( "%Y-%m-%d %H:%M", localtime( $candle->{time} ) );
    my $atr_label  = defined $atr ? sprintf( "%.4f", $atr ) : 'n/a';
    my $text       = sprintf(
        "%s  O %.2f  H %.2f  L %.2f  C %.2f  ATR %s",
        $time_label,
        $candle->{open},
        $candle->{high},
        $candle->{low},
        $candle->{close},
        $atr_label,
    );

    $self->{crosshair_info} = {
        index  => $index,
        x      => int( $scale->index_to_center_x($index) + 0.5 ),
        candle => $candle,
        atr    => $atr,
        text   => $text,
    };
}

# Switch active timeframe, recompute indicators, reset view
sub set_timeframe {
    my ($self, $tf) = @_;
    $self->{market}->set_timeframe($tf);
    $self->{indicators}->reset_all();

    $self->{indicators}->compute_all( $self->{market} );

    $self->reset_view();
}

sub reset_view {
    my ($self) = @_;
    $self->{offset}        = 0;
    $self->{visible_bars}  = 100;
    $self->{follow_last}   = 1;
    $self->{auto_follow}   = 1;
    $self->{manual_scroll} = 0;
    $self->{y_auto}        = 1;
    $self->{_render_state} = undef;
    $self->request_render();
}

sub _clamp_offset {
    my ($self, $offset) = @_;
    my $last = $self->{market}->last_index();
    $offset = 0     if $offset < 0;
    $offset = $last if $offset > $last;
    return $offset;
}

sub _set_manual_scroll {
    my ($self) = @_;
    $self->{follow_last}   = 0;
    $self->{auto_follow}   = 0;
    $self->{manual_scroll} = 1;
}

sub _sync_follow_state {
    my ($self) = @_;
    my $at_last = ($self->{offset} || 0) == 0 ? 1 : 0;
    $self->{follow_last}   = $at_last;
    $self->{auto_follow}   = $at_last;
    $self->{manual_scroll} = $at_last ? 0 : 1;
}

# Compute time labels for visible range (filtered to avoid overlap)
sub _nice_step_minutes {
    my ($self, $raw) = @_;
    my @steps = (1, 2, 3, 5, 10, 15, 20, 30, 60, 120, 180, 240, 360, 720, 1440);
    for my $s (@steps) {
        return $s if $raw <= $s;
    }
    return 1440;
}

sub compute_intraday_labels {
    my ($self, $start, $end, $scale) = @_;
    my %labels_by_index;

    my $bar_w = 8;
    if ($scale && ($scale->{visible_bars} || 0) > 0) {
        $bar_w = $scale->{x_width} / $scale->{visible_bars};
    }

    my $target_px      = 90;
    my $bars_per_label = int($target_px / ($bar_w || 1) + 0.999);
    $bars_per_label = 1 if $bars_per_label < 1;

    my $tf_min = $self->{market}{current_tf} || 1;
    $tf_min += 0;
    $tf_min = 1 if $tf_min <= 0;

    my $step_min = $self->_nice_step_minutes($bars_per_label * $tf_min);
    my $step_sec = $step_min * 60;

    my $prev_day_key = undef;
    my $prev_bucket  = undef;

    for my $i ($start .. $end) {
        my $ts = $self->{market}->get_timestamp($i);
        next unless defined $ts;

        my @lt = localtime($ts);
        my $day_key = sprintf("%04d-%02d-%02d", $lt[5] + 1900, $lt[4] + 1, $lt[3]);

        if (!defined $prev_day_key || $day_key ne $prev_day_key) {
            $self->_add_time_label( \%labels_by_index, {
                index    => $i,
                label    => sprintf("%02d/%02d", $lt[4] + 1, $lt[3]),
                time     => $ts,
                type     => 'day',
                priority => 3,
            });
            $prev_day_key = $day_key;
            $prev_bucket  = int($ts / $step_sec);
            next;
        }

        my $bucket = int($ts / $step_sec);
        next if defined $prev_bucket && $bucket == $prev_bucket;
        $prev_bucket = $bucket;

        my $label = $step_min < 60
            ? sprintf("%02d:%02d", $lt[2], $lt[1])
            : sprintf("%02d:00", $lt[2]);

        $self->_add_time_label( \%labels_by_index, {
            index    => $i,
            label    => $label,
            time     => $ts,
            type     => 'regular',
            priority => 5,
        });
    }

    for my $anchor ( @{ $self->{market}->compute_time_anchors() } ) {
        my $i = $anchor->{index};
        next if $i < $start || $i > $end;
        my $ts = $self->{market}->get_timestamp($i);
        next unless defined $ts;

        my @lt = localtime($ts);
        my $label =
              $anchor->{type} eq 'last'        ? sprintf( "Last %02d:%02d", $lt[2], $lt[1] )
            : $anchor->{type} eq 'midnight'    ? sprintf( "%02d/%02d 00:00", $lt[4] + 1, $lt[3] )
            : $anchor->{type} eq 'market_open' ? sprintf( "%02d:00", $lt[2] )
            : $anchor->{type} eq 'day'         ? sprintf( "%02d/%02d", $lt[4] + 1, $lt[3] )
            :                                    sprintf( "%02d:00", $lt[2] );

        $self->_add_time_label( \%labels_by_index, {
            index    => $i,
            label    => $label,
            time     => $ts,
            type     => $anchor->{type},
            priority => $anchor->{priority},
        });
    }

    if ( !%labels_by_index ) {
        for my $i ( $start, $end ) {
            my $ts = $self->{market}->get_timestamp($i);
            next unless defined $ts;
            my @lt = localtime($ts);
            $self->_add_time_label( \%labels_by_index, {
                index    => $i,
                label    => sprintf( "%02d:%02d", $lt[2], $lt[1] ),
                time     => $ts,
                type     => 'fallback',
                priority => 4,
            });
        }
    }

    for my $i ( $start, $end ) {
        my $ts = $self->{market}->get_timestamp($i);
        next unless defined $ts;
        my @lt = localtime($ts);
        $self->_add_time_label( \%labels_by_index, {
            index    => $i,
            label    => sprintf( "%02d:%02d", $lt[2], $lt[1] ),
            time     => $ts,
            type     => 'edge',
            priority => 4,
        });
    }

    my @labels = sort { $a->{index} <=> $b->{index} } values %labels_by_index;
    return \@labels;
}

sub _add_time_label {
    my ($self, $labels_by_index, $label) = @_;
    my $existing = $labels_by_index->{ $label->{index} };
    if ( !$existing || ( $label->{priority} // 5 ) < ( $existing->{priority} // 5 ) ) {
        $labels_by_index->{ $label->{index} } = $label;
    }
}

sub get_all_timestamps {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    return $self->compute_intraday_labels( $start, $end, $self->{price_scale} );
}

1;
