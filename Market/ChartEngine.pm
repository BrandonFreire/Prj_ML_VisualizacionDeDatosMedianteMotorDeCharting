package Market::ChartEngine;

use strict;
use warnings;
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
        y_auto         => 1,
        y_min_manual   => 0,
        y_max_manual   => 1,

        crosshair_x    => undef,
        crosshair_y    => undef,
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
        $self->_draw_crosshair_all();
    }
}

# Returns true when an incremental pan is safe (no Y rescale, no zoom, no resize)
sub _can_incremental {
    my ($self, $rs, $start, $end, $pscale, $n_visible, $pw, $ph) = @_;

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
    $c->bind( '<Button-4>', sub { $self->zoom(-1) } );
    $c->bind( '<Button-5>', sub { $self->zoom( 1) } );
    $c->bind( '<MouseWheel>', sub {
        my $e = $c->XEvent();
        $self->zoom( $e->Delta > 0 ? -1 : 1 );
        $c->xviewMoveto(0); $c->yviewMoveto(0);
    });

    $c->bind( '<Motion>', sub {
        my $e = $c->XEvent();
        $self->_on_mouse_move($e);
    });
    $c->bind( '<Leave>', sub {
        $self->{crosshair_x} = undef;
        $self->{crosshair_y} = undef;
        $self->{price_panel}->hide_crosshair();
        $self->{atr_panel}->hide_crosshair();
    });
}

# --- Public pan methods (called from market.pl) ---

sub drag_start {
    my ($self, $global_x) = @_;
    $self->{_drag_start_x}      = $global_x;
    $self->{_drag_start_offset} = $self->{offset};
}

sub drag_end {
    my ($self) = @_;
    $self->{_drag_start_x} = undef;
}

sub drag_move {
    my ($self, $global_x) = @_;
    return unless defined $self->{_drag_start_x};

    my $dx    = $global_x - $self->{_drag_start_x};
    my $bar_w = ( $self->{price_canvas}->width() || 900 ) / ( $self->{visible_bars} || 100 );
    $bar_w    = 0.5 if $bar_w < 0.5;

    my $new_off = $self->{_drag_start_offset} - int( $dx / $bar_w );
    $new_off = 0                             if $new_off < 0;
    $new_off = $self->{market}->last_index() if $new_off > $self->{market}->last_index();

    if ( $new_off != $self->{offset} ) {
        $self->{offset} = $new_off;
        $self->render();
    }
}

# delta < 0 = zoom in  (fewer visible bars, wider bars)
# delta > 0 = zoom out (more visible bars, overview)
sub zoom {
    my ($self, $delta) = @_;
    my $factor   = $delta > 0 ? 1.4 : 0.65;
    my $new_bars = int( $self->{visible_bars} * $factor + 0.5 );
    $new_bars = 5    if $new_bars < 5;
    $new_bars = 5000 if $new_bars > 5000;
    $self->{visible_bars} = $new_bars;
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
    my ($self, $event) = @_;
    $self->{crosshair_x} = $event->x;
    $self->{crosshair_y} = $event->y;
    $self->_draw_crosshair_all();
}

sub _draw_crosshair_all {
    my ($self) = @_;
    return unless defined $self->{crosshair_x};
    $self->{price_panel}->draw_crosshair( $self->{crosshair_x}, $self->{crosshair_y} );
    $self->{atr_panel}->draw_crosshair(   $self->{crosshair_x}, $self->{crosshair_y} );
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
    $self->{y_auto}        = 1;
    $self->{_render_state} = undef;
    $self->request_render();
}

# Compute time labels for visible range (filtered to avoid overlap)
sub compute_intraday_labels {
    my ($self, $start, $end, $scale) = @_;
    my @labels;
    my $prev_day  = -1;
    my $prev_hour = -1;

    for my $i ( $start .. $end ) {
        my $ts = $self->{market}->get_timestamp($i);
        next unless defined $ts;

        my @lt   = localtime($ts);
        my $hour = $lt[2];
        my $day  = $lt[3];
        my $mon  = $lt[4] + 1;

        my $label;
        if ( $day != $prev_day ) {
            $label     = sprintf( "%02d/%02d", $mon, $day );
            $prev_day  = $day;
            $prev_hour = $hour;
        }
        elsif ( $hour != $prev_hour ) {
            $label     = sprintf( "%02d:00", $hour );
            $prev_hour = $hour;
        }

        if ( defined $label ) {
            push @labels, { index => $i, label => $label, time => $ts };
        }
    }
    return \@labels;
}

sub get_all_timestamps {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    return $self->compute_intraday_labels( $start, $end, $self->{price_scale} );
}

1;
