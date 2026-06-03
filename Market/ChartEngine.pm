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
        _offset_exact  => 0.0,
        _x_offset      => 0.0,
        y_auto         => 1,
        y_min_manual   => 0,
        y_max_manual   => 1,

        crosshair_x       => undef,
        crosshair_y       => undef,
        _crosshair_source => 'price',
        pending_render    => 0,

        _drag_start_x      => undef,
        _drag_start_offset => 0,
        _render_state      => undef,

        on_scale_mode_change => undef,

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

# Calculates which candle indices are currently visible.
# offset=0 ancla la ultima vela historica en el borde derecho (pivot explicito).
# offset<0 produce espacio vacio futuro a la derecha.
sub compute_window {
    my ($self) = @_;
    my $last  = $self->{market}->last_index();
    my $end   = $last - $self->{offset};
    $end = 0 if $end < 0;
    # end > last es valido: significa espacio vacio futuro (no se clampea aqui)

    my $start = $end - $self->{visible_bars} + 1;
    $start = 0 if $start < 0;

    return ($start, $end);
}

# Ancla explicitamente la ultima vela historica al borde derecho (offset=0).
# Llamado por reset_view y por el atajo de teclado End.
sub goto_last {
    my ($self) = @_;
    $self->{offset}        = 0;
    $self->{_offset_exact} = 0.0;
    $self->{_x_offset}     = 0.0;
    $self->{_render_state} = undef;
    $self->request_render();
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
    my $last          = $self->{market}->last_index();

    # Cuando end > last hay espacio futuro vacio a la derecha.
    # El slice de datos se limita a indices validos, pero la escala usa
    # self->{visible_bars} para que el ancho de barra no cambie.
    my $data_end   = $end > $last ? $last : $end;
    my $data_slice = $self->{market}->get_slice($start, $data_end);
    return unless @$data_slice;

    my $n_visible = $end > $last ? $self->{visible_bars} : scalar @$data_slice;
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
    $price_scale->{x_offset} = $self->{_x_offset} // 0;
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
    $atr_scale->{x_offset} = $self->{_x_offset} // 0;
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

    return 0 if $self->{_x_offset} != 0;   # x_offset sub-pixel requiere full render
    return 0 if $self->{offset} < 0;       # espacio futuro requiere full render
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

    # --- Price scale (must come after candles so lastprice draws on ready canvas) ---
    $psc->delete('all');
    $pscale->_draw_y_scale($psc);
    $self->{price_panel}->render_last_visible_price($pc);

    # --- ATR panel ---
    $ac->delete('all');
    $self->{atr_panel}->set_scale($ascale);
    $self->{atr_panel}->render( $ac, $atr_slice, $ascale );

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

    # Crosshair via MainWindow: <Motion> en canvas-level no dispara de forma confiable
    # en X11/Linux. Se usan coords de pantalla (X,Y mayusculas) y se convierten a canvas-local
    # con rootx/rooty, igual que funciona el pan con Ev('X').
    my $mw = $self->{price_canvas}->MainWindow;
    $mw->bind( '<Motion>', [ sub {
        $self->_handle_global_motion( $_[1], $_[2] );
    }, Tk::Ev('X'), Tk::Ev('Y') ] );
    $mw->bind( '<Leave>', sub { $self->_hide_crosshair_all() } );

    # Ctrl+scroll al nivel del MainWindow (mas confiable que canvas-level en X11).
    # crosshair_x ya contiene la coord canvas-local exacta bajo el cursor.
    $mw->bind( '<Control-Button-4>', sub {
        $self->zoom_at( -1, $self->{crosshair_x} );
    });
    $mw->bind( '<Control-Button-5>', sub {
        $self->zoom_at(  1, $self->{crosshair_x} );
    });
}

sub _bind_all_canvas {
    my ($self, $c) = @_;

    # Zoom normal (sin Ctrl): ajusta visible_bars manteniendo el borde derecho fijo
    $c->bind( '<Button-4>', sub { $self->zoom(-1) } );
    $c->bind( '<Button-5>', sub { $self->zoom( 1) } );
    $c->bind( '<MouseWheel>', sub {
        my $e = $c->XEvent();
        $self->zoom( $e->Delta > 0 ? -1 : 1 );
        $c->xviewMoveto(0); $c->yviewMoveto(0);
    });

    # (Ctrl+scroll se maneja al nivel del MainWindow en bind_events, no aqui)
}

# Convierte coords de pantalla (rx, ry) a coords locales del canvas para el crosshair.
# Se usa Motion al nivel del MainWindow porque es mas confiable que canvas-level en X11.
sub _handle_global_motion {
    my ($self, $rx, $ry) = @_;

    my $pc = $self->{price_canvas};
    my $ac = $self->{atr_canvas};

    my $pcx = $rx - $pc->rootx;
    my $pcy = $ry - $pc->rooty;
    if ( $pcx >= 0 && $pcx < ( $pc->width || 900 )
      && $pcy >= 0 && $pcy < ( $pc->height || 500 ) ) {
        $self->_on_mouse_move_xy( $pcx, $pcy, 'price' );
        return;
    }

    my $acx = $rx - $ac->rootx;
    my $acy = $ry - $ac->rooty;
    if ( $acx >= 0 && $acx < ( $ac->width || 900 )
      && $acy >= 0 && $acy < ( $ac->height || 150 ) ) {
        $self->_on_mouse_move_xy( $acx, $acy, 'atr' );
        return;
    }

    $self->_hide_crosshair_all();
}

sub _hide_crosshair_all {
    my ($self) = @_;
    return unless defined $self->{crosshair_x};
    $self->{crosshair_x} = undef;
    $self->{crosshair_y} = undef;
    $self->{price_panel}->hide_crosshair();
    $self->{atr_panel}->hide_crosshair();
}

# --- Public pan methods (called from market.pl) ---

sub drag_start {
    my ($self, $global_x, $global_y) = @_;
    $self->{_drag_start_x}      = $global_x;
    $self->{_drag_start_y}      = $global_y;
    $self->{_drag_start_offset} = $self->{offset};
    # Capturar rango Y al inicio del drag para pan vertical relativo al punto de inicio
    $self->{_drag_start_y_min}  = $self->{y_min_manual};
    $self->{_drag_start_y_max}  = $self->{y_max_manual};
}

sub drag_end {
    my ($self) = @_;
    $self->{_drag_start_x} = undef;
    $self->{_drag_start_y} = undef;
}

sub drag_move {
    my ($self, $global_x, $global_y) = @_;
    return unless defined $self->{_drag_start_x};

    # --- Pan horizontal (siempre) ---
    my $dx    = $global_x - $self->{_drag_start_x};
    my $bar_w = ( $self->{price_canvas}->width() || 900 ) / ( $self->{visible_bars} || 100 );
    $bar_w    = 0.5 if $bar_w < 0.5;

    my $new_off    = $self->{_drag_start_offset} + int( $dx / $bar_w );
    my $max_future = int( $self->{visible_bars} * 0.3 );   # hasta 30% de espacio futuro
    $new_off = -$max_future                  if $new_off < -$max_future;
    $new_off = $self->{market}->last_index() if $new_off > $self->{market}->last_index();

    my $needs_render = ( $new_off != $self->{offset} || $self->{_x_offset} != 0 );

    # --- Pan vertical (solo en modo manual) ---
    if ( !$self->{y_auto} && defined $self->{_drag_start_y} && $self->{price_scale} ) {
        my $dy    = $global_y - $self->{_drag_start_y};   # positivo = mouse hacia abajo
        my $range = $self->{_drag_start_y_max} - $self->{_drag_start_y_min};
        my $ph    = $self->{price_scale}{y_height} || 400;

        # En pantalla Y crece hacia abajo, pero precio crece hacia arriba → invertir signo
        my $price_shift = $dy * $range / $ph;

        my $new_y_min = $self->{_drag_start_y_min} + $price_shift;
        my $new_y_max = $self->{_drag_start_y_max} + $price_shift;

        if ( abs($new_y_min - $self->{y_min_manual}) > 1e-9
          || abs($new_y_max - $self->{y_max_manual}) > 1e-9 ) {
            $self->{y_min_manual}  = $new_y_min;
            $self->{y_max_manual}  = $new_y_max;
            $self->{_render_state} = undef;   # Y cambio → full render obligatorio
            $needs_render = 1;
        }
    }

    if ($needs_render) {
        $self->{offset}        = $new_off;
        $self->{_offset_exact} = $new_off * 1.0;
        if ( $self->{_x_offset} != 0 ) {
            $self->{_x_offset}     = 0.0;
            $self->{_render_state} = undef;
        }
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

# Zoom centrado en cursor_x: la vela bajo el cursor mantiene su posicion en pantalla.
#
# Problema del enfoque anterior (frac-based): redondear new_bars introduce un error
# que se acumula en cada paso de zoom consecutivo porque target_ix se recalcula
# desde la escala ya redondeada.
#
# Solucion: guardar _offset_exact (float) entre llamadas. Cada llamada calcula
# target_ix desde _offset_exact (no desde el offset entero redondeado), por lo que
# el error por paso es como maximo 0.5 * bar_w y NO se acumula.
#
# Derivacion:
#   target_ix  = start_exact + cursor_x * old_bars / pw
#   new_start  = target_ix - cursor_x * new_bars / pw
#   new_end    = new_start + new_bars - 1
#   new_offset = last - new_end
sub zoom_at {
    my ($self, $delta, $cursor_x) = @_;

    my $old_bars = $self->{visible_bars};
    my $factor   = $delta > 0 ? 1.4 : 0.65;
    my $new_bars = int( $old_bars * $factor + 0.5 );
    $new_bars = 5    if $new_bars < 5;
    $new_bars = 5000 if $new_bars > 5000;
    return if $new_bars == $old_bars;

    my $pw = $self->{price_canvas}->width() || 900;
    $cursor_x //= $pw / 2;
    $cursor_x = 0   if $cursor_x < 0;
    $cursor_x = $pw if $cursor_x > $pw;

    my $last      = $self->{market}->last_index();
    my $old_bar_w = $pw / $old_bars;
    my $new_bar_w = $pw / $new_bars;

    # Indice fraccional exacto bajo el cursor (usa _x_offset actual para precision)
    my $start     = $last - $self->{offset} - $old_bars + 1;
    my $frac_ix   = ($cursor_x - ($self->{_x_offset} // 0)) / $old_bar_w + $start - 0.5;

    # Calcular new_off entero (aproximacion necesaria por indices enteros)
    my $new_end_exact    = $frac_ix - $cursor_x * $new_bars / $pw + $new_bars - 0.5;
    my $new_offset_exact = $last - $new_end_exact;
    my $new_off          = int( $new_offset_exact + 0.5 );

    my $clamped = 0;
    if ( $new_off < 0 )     { $new_off = 0;     $clamped = 1; }
    if ( $new_off > $last ) { $new_off = $last;  $clamped = 1; }

    $self->{_offset_exact} = $clamped ? $new_off * 1.0 : $new_offset_exact;

    # Calcular _x_offset sub-pixel para que frac_ix quede exactamente en cursor_x.
    # Esto absorbe el error de redondeo de new_off => drift = 0 entre pasos consecutivos.
    my $new_start = $last - $new_off - $new_bars + 1;
    my $new_x_offset = $clamped ? 0.0
                                : $cursor_x - ($frac_ix - $new_start + 0.5) * $new_bar_w;
    $self->{_x_offset} = $new_x_offset;

    $self->{visible_bars}  = $new_bars;
    $self->{offset}        = $new_off;
    $self->{_render_state} = undef;
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

    my $was_auto       = $self->{y_auto};
    $self->{y_auto}        = 0;
    $self->{y_min_manual}  = $mid - $new_half;
    $self->{y_max_manual}  = $mid + $new_half;
    $self->{_render_state} = undef;

    # Notificar cambio de modo solo si cambia (de auto a manual)
    if ($was_auto && $self->{on_scale_mode_change}) {
        $self->{on_scale_mode_change}->(0);
    }

    $self->request_render();
}

sub toggle_auto_scale {
    my ($self) = @_;
    if ( $self->{y_auto} && $self->{price_scale} ) {
        # Al entrar a manual: copiar el rango actual para no perder las velas de vista
        $self->{y_min_manual} = $self->{price_scale}{y_min};
        $self->{y_max_manual} = $self->{price_scale}{y_max};
    }
    $self->{y_auto}        = !$self->{y_auto};
    $self->{_render_state} = undef;
    $self->{on_scale_mode_change}->( $self->{y_auto} ) if $self->{on_scale_mode_change};
    $self->request_render();
    return $self->{y_auto};
}

sub set_scale_mode_callback {
    my ($self, $cb) = @_;
    $self->{on_scale_mode_change} = $cb;
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

sub _on_mouse_move_xy {
    my ($self, $x, $y, $source) = @_;
    $self->{crosshair_x}       = $x;
    $self->{crosshair_y}       = $y;
    $self->{_crosshair_source} = $source // 'price';
    $self->_draw_crosshair_all();
}

sub _draw_crosshair_all {
    my ($self) = @_;
    return unless defined $self->{crosshair_x} && $self->{price_scale};

    my $scale = $self->{price_scale};

    # Snap la linea vertical al centro de la barra mas cercana
    my $ix = $scale->x_to_index( $self->{crosshair_x} );
    my $lo = $scale->{start_index};
    my $hi = $scale->{start_index} + $scale->{visible_bars} - 1;
    $ix    = $lo if $ix < $lo;
    $ix    = $hi if $ix > $hi;
    my $snapped_x = int( $scale->index_to_center_x($ix) + 0.5 );

    # La linea horizontal solo se dibuja cuando el mouse esta sobre el panel de precio
    my $price_y = ( $self->{_crosshair_source} eq 'price' ) ? $self->{crosshair_y} : undef;
    $self->{price_panel}->draw_crosshair( $snapped_x, $price_y );

    # Label de fecha/hora en el time-axis (precio y ATR sincronizados)
    my $ts = $self->{market}->get_timestamp($ix);
    $self->{price_panel}->draw_crosshair_time_label( $snapped_x, $ts );
    $self->{atr_panel}->draw_crosshair_time_label(   $snapped_x, $ts );

    # OHLC legend en la esquina superior izquierda del canvas de precio
    my $candle = $self->{market}->get_candle($ix);
    my $prev   = $ix > 0 ? $self->{market}->get_candle($ix - 1) : undef;
    $self->{price_panel}->draw_ohlc_legend($candle, $prev ? $prev->{close} : undef);

    # Valor ATR en la barra bajo el cursor
    my $atr_val;
    my $atr_obj = $self->{indicators}->get('ATR');
    if ($atr_obj) {
        my $vals = $atr_obj->get_values();
        $atr_val = $vals->[$ix] if defined $vals && $ix >= 0 && $ix < scalar @$vals;
    }
    # $atr_y definido solo cuando el mouse esta sobre el panel ATR
    my $atr_y = ( $self->{_crosshair_source} eq 'atr' ) ? $self->{crosshair_y} : undef;
    $self->{atr_panel}->draw_crosshair( $snapped_x, $atr_val, $atr_y );
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
    $self->{visible_bars}  = 100;
    $self->{y_auto}        = 1;
    $self->{_render_state} = undef;
    $self->{on_scale_mode_change}->(1) if $self->{on_scale_mode_change};
    $self->goto_last();   # ancla explicitamente la ultima vela al borde derecho
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
    my @labels;

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
            push @labels, {
                index => $i,
                label => sprintf("%02d/%02d", $lt[4] + 1, $lt[3]),
                time  => $ts,
            };
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

        push @labels, { index => $i, label => $label, time => $ts };
    }

    return \@labels;
}

sub get_all_timestamps {
    my ($self) = @_;
    my ($start, $end) = $self->compute_window();
    return $self->compute_intraday_labels( $start, $end, $self->{price_scale} );
}

1;
