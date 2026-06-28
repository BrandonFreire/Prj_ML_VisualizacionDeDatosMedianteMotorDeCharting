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

        # --- Overlays SMC y Liquidez ---
        overlays => [],   # lista de objetos overlay (respond a ->render(...))

        # --- Sistema Replay ---
        replay_mode    => 0,       # 1 = en modo replay
        replay_cursor  => undef,   # indice de la ultima vela visible (barrera temporal)
        replay_playing => 0,       # 1 = avanzando automaticamente
        replay_speed   => 400,     # ms entre pasos en modo play normal
        _replay_timer  => undef,   # ID del after() activo
        on_replay_state_change => undef,  # callback(state) para actualizar UI

        # ATR independent Y scale
        y_auto_atr         => 1,
        y_min_atr          => 0,
        y_max_atr          => 1,
        _atr_vy_drag_start => undef,

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

# Calcula la ventana virtual y los indices de datos reales visibles.
# Retorna: (v_start, v_end, d_start, d_end)
#   v_start/v_end = indices virtuales (pueden ser negativos o > last para espacio vacio)
#   d_start/d_end = indices reales con datos, clampeados a [0, last]
# Cuando v_start < 0 se ve espacio vacio a la izquierda (antes de la primera vela).
# Cuando v_end > last se ve espacio vacio a la derecha (despues de la ultima vela).
sub compute_window {
    my ($self) = @_;
    my $last    = $self->{market}->last_index();
    my $n       = $self->{visible_bars};
    my $v_end   = $last - $self->{offset};
    my $v_start = $v_end - $n + 1;

    # Replay: nunca mostrar velas mas alla del cursor temporal
    if ( $self->{replay_mode} && defined $self->{replay_cursor} ) {
        $v_end = $self->{replay_cursor} if $v_end > $self->{replay_cursor};
    }

    my $d_start = $v_start < 0     ? 0     : $v_start;
    my $d_end   = $v_end   > $last ? $last : $v_end;

    # Rango vacio cuando la ventana esta completamente fuera de los datos
    if ( $d_end < 0 || $d_start > $last ) {
        $d_end = $d_start - 1;
    }

    return ( $v_start, $v_end, $d_start, $d_end );
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

    # v_start/v_end = ventana virtual (puede salir del rango de datos → espacio vacio)
    # d_start/d_end = indices reales con datos [0, last]
    my ( $v_start, $v_end, $d_start, $d_end ) = $self->compute_window();
    my $data_slice = $d_end >= $d_start
        ? $self->{market}->get_slice( $d_start, $d_end )
        : [];
    return unless @$data_slice;

    my $n_visible = $self->{visible_bars};   # siempre el ancho completo de la ventana
    my $pw = $self->{price_canvas}->width()  || 900;
    my $ph = $self->{price_canvas}->height() || 500;
    my $aw = $self->{atr_canvas}->width()    || 900;
    my $ah = $self->{atr_canvas}->height()   || 150;

    # La escala usa v_start como origen: index_to_center_x posiciona correctamente
    # las velas reales (con indice >= 0) dejando espacio vacio donde no hay datos.
    my $price_scale = Market::Panels::Scales->new(
        x_left       => 0,
        x_width      => $pw,
        start_index  => $v_start,   # virtual — puede ser negativo
        visible_bars => $n_visible, # siempre el ancho completo
        y_top        => 0,
        y_height     => $ph - $TIME_AXIS_H,
        y_min        => 0,
        y_max        => 1,
    );
    # data_start_index indica donde empieza el slice de datos dentro de la ventana virtual
    $price_scale->{data_start_index} = $d_start;

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

    # ATR scale — misma logica de ventana virtual
    my $atr_slice = $self->{indicators}->slice_array( 'ATR', $d_start, $d_end );

    my $atr_scale = Market::Panels::Scales->new(
        x_left       => 0,
        x_width      => $aw,
        start_index  => $v_start,
        visible_bars => $n_visible,
        y_top        => 0,
        y_height     => $ah,
        y_min        => 0,
        y_max        => 1,
    );
    $atr_scale->{data_start_index} = $d_start;

    if ( $self->{y_auto_atr} ) {
        my ( $a_min, $a_max ) = $self->{atr_panel}->get_y_range($atr_slice);
        $atr_scale->{y_min} = $a_min;
        $atr_scale->{y_max} = $a_max;
    }
    else {
        $atr_scale->{y_min} = $self->{y_min_atr};
        $atr_scale->{y_max} = $self->{y_max_atr};
    }
    $atr_scale->{x_offset} = $self->{_x_offset} // 0;
    $self->{atr_scale} = $atr_scale;

    # Dispatch to incremental or full render
    my $rs = $self->{_render_state};
    if ( $rs && $self->_can_incremental( $rs, $v_start, $v_end, $d_start, $d_end, $price_scale, $n_visible, $pw, $ph ) ) {
        $self->_incremental_pan( $v_start, $v_end, $d_start, $d_end, $data_slice, $price_scale, $atr_slice, $atr_scale, $rs );
    }
    else {
        $self->_full_render( $d_start, $d_end, $data_slice, $price_scale, $atr_slice, $atr_scale );
    }

    # Save state for next incremental check
    $self->{_render_state} = {
        v_start      => $v_start,
        v_end        => $v_end,
        d_start      => $d_start,
        d_end        => $d_end,
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
    my ($self, $rs, $v_start, $v_end, $d_start, $d_end, $pscale, $n_visible, $pw, $ph) = @_;

    return 0 if $self->{_x_offset} != 0;
    return 0 if $rs->{pw} != $pw || $rs->{ph} != $ph;
    return 0 if $rs->{visible_bars} != $n_visible;

    my $delta = abs( $v_start - $rs->{v_start} );
    return 0 if $delta == 0;
    return 0 if $delta >= $n_visible;

    my $p_range = $rs->{y_max} - $rs->{y_min};
    return 0 if $p_range <= 0;
    my $p_diff = abs( $pscale->{y_max} - $rs->{y_max} )
               + abs( $pscale->{y_min} - $rs->{y_min} );
    return 0 if $p_diff > $p_range * 0.01;

    return 1;
}

# Complete redraw of all panels and scales
sub _full_render {
    my ($self, $d_start, $d_end, $data_slice, $pscale, $atr_slice, $ascale) = @_;

    my $pc  = $self->{price_canvas};
    my $psc = $self->{price_scale_canvas};
    my $ac  = $self->{atr_canvas};
    my $asc = $self->{atr_scale_canvas};

    # --- Price panel ---
    $pc->delete('all');
    $self->{price_panel}->set_scale($pscale);
    $self->{price_panel}->render( $pc, $data_slice, $pscale );
    my $ts = $self->compute_intraday_labels( $d_start, $d_end, $pscale );
    $self->{price_panel}->draw_time_axis( $pc, $ts );

    # --- Overlays SMC y Liquidez (encima de las velas, debajo del precio final) ---
    my $cur_bar = $self->{replay_mode} && defined $self->{replay_cursor}
                  ? $self->{replay_cursor} : $d_end;
    for my $ov ( @{ $self->{overlays} } ) {
        $ov->render( $pc, $d_start, $d_end, $pscale, $cur_bar );
    }

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
    my ($self, $v_start, $v_end, $d_start, $d_end, $data_slice, $pscale, $atr_slice, $ascale, $rs) = @_;

    # El delta virtual determina cuantos pixeles se desplazan las velas existentes
    my $delta = $v_start - $rs->{v_start};
    my $bar_w = $pscale->{x_width} / ( $pscale->{visible_bars} || 1 );
    my $dx    = -$delta * $bar_w;

    my $pc  = $self->{price_canvas};
    my $psc = $self->{price_scale_canvas};
    my $ac  = $self->{atr_canvas};
    my $asc = $self->{atr_scale_canvas};

    $self->{price_panel}->set_scale($pscale);
    $self->{atr_panel}->set_scale($ascale);

    # Shift all candles O(1)
    $pc->move( 'candles', $dx, 0 );

    if ( $delta > 0 ) {
        # Panned left: eliminar velas que salieron por la izquierda, agregar a la derecha
        $pc->delete("ci_$_") for $rs->{d_start} .. $d_start - 1;
        for my $i ( 0 .. $#$data_slice ) {
            my $ix = $d_start + $i;
            $self->{price_panel}->render_candle( $pc, $data_slice->[$i], $ix, $pscale )
                if $ix > $rs->{d_end};
        }
    }
    else {
        # Panned right: eliminar velas que salieron por la derecha, agregar a la izquierda
        $pc->delete("ci_$_") for ( $d_end + 1 ) .. $rs->{d_end};
        for my $i ( 0 .. $#$data_slice ) {
            my $ix = $d_start + $i;
            $self->{price_panel}->render_candle( $pc, $data_slice->[$i], $ix, $pscale )
                if $ix < $rs->{d_start};
        }
    }

    # Update last candle info for render_last_visible_price
    my $last_c = $data_slice->[-1];
    $self->{price_panel}{_last_close} = $last_c->{close};
    $self->{price_panel}{_last_open}  = $last_c->{open};

    # Redraw price grid
    $pc->delete('grid');
    for my $v ( $pscale->get_nice_levels() ) {
        my $y = $pscale->value_to_y($v);
        next if $y < 0 || $y > $pscale->{y_height};
        $pc->createLine( 0, $y, $pscale->{x_width}, $y,
            -fill => '#1e2130', -tags => ['grid'] );
    }
    $pc->lower( 'grid', 'candles' ) if $pc->find( 'withtag', 'candles' );

    # Redraw time axis
    $pc->delete('timeaxis');
    my $ts = $self->compute_intraday_labels( $d_start, $d_end, $pscale );
    $self->{price_panel}->draw_time_axis( $pc, $ts );

    # Redraw overlays
    my $cur_bar2 = $self->{replay_mode} && defined $self->{replay_cursor}
                   ? $self->{replay_cursor} : $d_end;
    for my $ov ( @{ $self->{overlays} } ) {
        $ov->render( $pc, $d_start, $d_end, $pscale, $cur_bar2 );
    }

    # Redraw last price label
    $pc->delete('lastprice');
    $psc->delete('all');
    $pscale->_draw_y_scale($psc);
    $self->{price_panel}->render_last_visible_price($pc);

    # Redraw ATR (full, fast)
    $ac->delete('grid');
    $ac->delete('atr');
    $self->{atr_panel}->render( $ac, $atr_slice, $ascale );
    for my $i ( reverse 0 .. $#$atr_slice ) {
        if ( defined $atr_slice->[$i] ) {
            $self->{atr_panel}{_last_atr} = $atr_slice->[$i];
            last;
        }
    }

    # Redraw ATR scale + last ATR label
    $ac->delete('lastatr');
    $asc->delete('all');
    $ascale->_draw_y_scale($asc);
    $self->{atr_panel}->render_last_visible_value($ac);

    $pc->raise('crosshair');
    $ac->raise('crosshair');
}

# Bind all user input events
sub bind_events {
    my ($self) = @_;
    $self->_bind_all_canvas( $self->{price_canvas} );
    $self->_bind_all_canvas( $self->{atr_canvas} );

    # ---------------------------------------------------------------
    # Escala Y del PRECIO — drag vertical + rueda para zoom vertical
    # ---------------------------------------------------------------
    # Por que usamos pointery() en lugar de XEvent()->y:
    #   XEvent() puede devolver coordenadas relativas al canvas, que dejan de
    #   ser utiles cuando el mouse sale del canvas durante el drag (la diferencia
    #   entre movimientos consecutivos se distorsiona). pointery() da la Y
    #   absoluta de pantalla, que siempre es continua durante todo el arrastre.
    #
    # Por que Tk::break():
    #   Los eventos se propagan en cadena de bind-tags:
    #     canvas → Canvas (clase) → "." (toplevel/MainWindow) → "all"
    #   Sin break, el MainWindow veria el ButtonPress y llamaria drag_start(),
    #   activando el pan horizontal al mismo tiempo que el zoom vertical.
    #   Tk::break() corta la cadena despues del binding del canvas.
    # ---------------------------------------------------------------
    my $psc = $self->{price_scale_canvas};

    $psc->bind( '<ButtonPress-1>', sub {
        # Guardar Y absoluta de pantalla como referencia de inicio del drag
        $self->{_vy_drag_start} = $psc->pointery();

        # Si estabamos en auto, pasar a manual antes del primer arrastre
        if ( $self->{y_auto} ) {
            if ( $self->{price_scale} ) {
                $self->{y_min_manual} = $self->{price_scale}{y_min};
                $self->{y_max_manual} = $self->{price_scale}{y_max};
            }
            $self->{y_auto} = 0;
            $self->{on_scale_mode_change}->(0) if $self->{on_scale_mode_change};
        }

        Tk::break();   # impide que MainWindow procese este click como pan horizontal
    });

    $psc->bind( '<B1-Motion>', sub {
        my $current_y = $psc->pointery();
        my $dy = $current_y - ( $self->{_vy_drag_start} // $current_y );
        if ( $dy != 0 ) {
            $self->_vertical_drag($dy);
            $self->{_vy_drag_start} = $current_y;
        }
        Tk::break();
    });

    $psc->bind( '<ButtonRelease-1>', sub {
        $self->{_vy_drag_start} = undef;
    });

    # Rueda del mouse sobre escala Y → zoom vertical (no horizontal)
    # Button-4 = scroll arriba = zoom IN (rango mas chico, velas mas grandes)
    # Button-5 = scroll abajo  = zoom OUT (rango mas grande, velas mas chicas)
    $psc->bind( '<Button-4>', sub { $self->_vertical_zoom(0.85);     Tk::break() });
    $psc->bind( '<Button-5>', sub { $self->_vertical_zoom(1 / 0.85); Tk::break() });

    # ---------------------------------------------------------------
    # Escala Y del ATR — zoom vertical INDEPENDIENTE del de precio
    # ---------------------------------------------------------------
    my $asc = $self->{atr_scale_canvas};

    $asc->bind( '<ButtonPress-1>', sub {
        $self->{_atr_vy_drag_start} = $asc->pointery();

        if ( $self->{y_auto_atr} ) {
            if ( $self->{atr_scale} ) {
                $self->{y_min_atr} = $self->{atr_scale}{y_min};
                $self->{y_max_atr} = $self->{atr_scale}{y_max};
            }
            $self->{y_auto_atr} = 0;
        }

        Tk::break();
    });

    $asc->bind( '<B1-Motion>', sub {
        my $current_y = $asc->pointery();
        my $dy = $current_y - ( $self->{_atr_vy_drag_start} // $current_y );
        if ( $dy != 0 ) {
            $self->_vertical_drag_atr($dy);
            $self->{_atr_vy_drag_start} = $current_y;
        }
        Tk::break();
    });

    $asc->bind( '<ButtonRelease-1>', sub {
        $self->{_atr_vy_drag_start} = undef;
    });

    $asc->bind( '<Button-4>', sub { $self->_vertical_zoom_atr(0.85);     Tk::break() });
    $asc->bind( '<Button-5>', sub { $self->_vertical_zoom_atr(1 / 0.85); Tk::break() });

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

    my $new_off = $self->{_drag_start_offset} + int( $dx / $bar_w );
    # Permitir padding de un ancho de ventana en cada extremo para espacio vacio
    my $pad     = $self->{visible_bars};
    my $max_off = $self->{market}->last_index() + $pad;
    my $min_off = -$pad;
    $new_off = $min_off if $new_off < $min_off;
    $new_off = $max_off if $new_off > $max_off;

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
    $self->{price_canvas}->toplevel->title("Market Chart | " . $self->tf_label($tf) . "  [velas: $new_bars]");
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
    $self->{price_canvas}->toplevel->title("Market Chart | " . $self->tf_label($tf) . "  [velas: $new_bars]");
    $self->request_render();
}

sub _horizontal_zoom { my ($self, $delta) = @_; $self->zoom($delta) }

sub _vertical_drag {
    my ($self, $dy) = @_;
    return unless defined $self->{price_scale};

    # IMPORTANTE: leer de y_min_manual/y_max_manual (no de price_scale) cuando ya estamos
    # en modo manual. price_scale refleja el ultimo RENDER completado; si B1-Motion llega
    # varias veces antes del siguiente render (16 ms), cada llamada tomaría el mismo
    # valor obsoleto y el zoom no acumularia. Con y_min_manual leemos el valor ya
    # actualizado por la llamada anterior, aunque el canvas todavia no redibujó.
    my ($y_min, $y_max);
    if ( $self->{y_auto} ) {
        $y_min = $self->{price_scale}{y_min};
        $y_max = $self->{price_scale}{y_max};
    } else {
        $y_min = $self->{y_min_manual};
        $y_max = $self->{y_max_manual};
    }
    my $range  = $y_max - $y_min;
    my $h      = $self->{price_scale}{y_height} || 400;

    # dy > 0 = arrastrar hacia abajo = zoom IN (rango se achica) — igual que TradingView
    my $factor = 1 - $dy / $h;
    $factor = 0.1  if $factor < 0.1;
    $factor = 10.0 if $factor > 10.0;

    my $mid      = ( $y_max + $y_min ) / 2;
    my $new_half = ( $range / 2 ) * $factor;

    my $was_auto = $self->{y_auto};
    $self->{y_auto}        = 0;
    $self->{y_min_manual}  = $mid - $new_half;
    $self->{y_max_manual}  = $mid + $new_half;
    $self->{_render_state} = undef;

    if ( $was_auto && $self->{on_scale_mode_change} ) {
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

# Registra un overlay; debe responder a ->render($canvas,$d_start,$d_end,$scale,$cur_bar)
sub add_overlay {
    my ($self, $overlay) = @_;
    push @{ $self->{overlays} }, $overlay;
}

# Registra el indicador SMC para recomputarlo al cambiar timeframe
sub set_smc_indicator {
    my ($self, $ind) = @_;
    $self->{_smc_indicator} = $ind;
}

sub set_replay_callback {
    my ($self, $cb) = @_;
    $self->{on_replay_state_change} = $cb;
}

# ================================================================
# SISTEMA REPLAY — Seccion 3 de la especificacion
# ================================================================
# El cursor de replay es la "barrera temporal": ninguna vela con
# indice > replay_cursor se mostrara en pantalla ni en indicadores.
# compute_window() aplica este clamp en cada render.
# Los indicadores ya estan precomputados para todo el historico;
# el slice los limita al rango visible.
# ================================================================

sub start_replay {
    my ($self) = @_;
    # Tomar el borde derecho actual de la vista como punto de inicio del replay
    my ($v_start, $v_end, $d_start, $d_end) = $self->compute_window();
    $self->{replay_mode}    = 1;
    $self->{replay_cursor}  = $d_end;
    $self->{replay_playing} = 0;
    $self->{replay_speed}   = 400;
    $self->{_render_state}  = undef;
    $self->{on_replay_state_change}->('started') if $self->{on_replay_state_change};
    $self->request_render();
}

sub exit_replay {
    my ($self) = @_;
    $self->_stop_replay_timer();
    $self->{replay_mode}    = 0;
    $self->{replay_playing} = 0;
    $self->{replay_cursor}  = undef;
    $self->{_render_state}  = undef;
    $self->{on_replay_state_change}->('exited') if $self->{on_replay_state_change};
    $self->goto_last();
}

# Avanza el cursor una barra hacia el futuro y actualiza el offset
# para que el cursor quede visible en el borde derecho de la vista.
sub step_forward {
    my ($self) = @_;
    return unless $self->{replay_mode};
    my $real_last = $self->{market}->last_index();
    return if $self->{replay_cursor} >= $real_last;
    $self->{replay_cursor}++;
    $self->_anchor_cursor_to_right_edge();
    $self->{_render_state} = undef;
    $self->request_render();
}

sub step_backward {
    my ($self) = @_;
    return unless $self->{replay_mode};
    return if $self->{replay_cursor} <= 0;
    $self->{replay_cursor}--;
    $self->_anchor_cursor_to_right_edge();
    $self->{_render_state} = undef;
    $self->request_render();
}

sub play_replay {
    my ($self, $speed) = @_;
    return unless $self->{replay_mode};
    $self->_stop_replay_timer();
    $self->{replay_speed}   = $speed // 400;
    $self->{replay_playing} = 1;
    $self->{on_replay_state_change}->('playing') if $self->{on_replay_state_change};
    $self->_tick_replay();
}

sub pause_replay {
    my ($self) = @_;
    $self->_stop_replay_timer();
    $self->{replay_playing} = 0;
    $self->{on_replay_state_change}->('paused') if $self->{on_replay_state_change};
}

sub toggle_play_replay {
    my ($self) = @_;
    return unless $self->{replay_mode};
    if ( $self->{replay_playing} ) {
        $self->pause_replay();
    } else {
        $self->play_replay( $self->{replay_speed} );
    }
}

sub fast_forward_replay {
    my ($self) = @_;
    $self->play_replay(50);   # 50 ms por barra = velocidad alta
}

sub _tick_replay {
    my ($self) = @_;
    return unless $self->{replay_playing} && $self->{replay_mode};

    my $real_last = $self->{market}->last_index();
    if ( $self->{replay_cursor} >= $real_last ) {
        $self->{replay_playing} = 0;
        $self->{_replay_timer}  = undef;
        $self->{on_replay_state_change}->('end') if $self->{on_replay_state_change};
        return;
    }

    $self->{replay_cursor}++;
    $self->_anchor_cursor_to_right_edge();
    $self->{_render_state} = undef;
    $self->request_render();

    $self->{_replay_timer} = $self->{price_canvas}->after(
        $self->{replay_speed},
        sub { $self->_tick_replay() }
    );
}

sub _stop_replay_timer {
    my ($self) = @_;
    if ( defined $self->{_replay_timer} ) {
        eval { $self->{price_canvas}->after_cancel( $self->{_replay_timer} ) };
        $self->{_replay_timer} = undef;
    }
}

# Ajusta el offset para que replay_cursor quede en el borde derecho visible.
# Si el cursor retrocede mas alla del borde izquierdo, ajusta en esa direccion.
sub _anchor_cursor_to_right_edge {
    my ($self) = @_;
    my $cursor    = $self->{replay_cursor};
    my $real_last = $self->{market}->last_index();

    # offset tal que v_end = cursor
    my $new_off = $real_last - $cursor;
    $new_off = 0 if $new_off < 0;

    $self->{offset}        = $new_off;
    $self->{_offset_exact} = $new_off * 1.0;
    $self->{_x_offset}     = 0.0;
}

sub _vertical_zoom {
    my ($self, $factor) = @_;
    return unless defined $self->{price_scale};
    # Mismo principio: leer de y_min_manual si ya estamos en modo manual
    my ($y_min, $y_max);
    if ( $self->{y_auto} ) {
        $y_min = $self->{price_scale}{y_min};
        $y_max = $self->{price_scale}{y_max};
    } else {
        $y_min = $self->{y_min_manual};
        $y_max = $self->{y_max_manual};
    }
    my $mid      = ( $y_max + $y_min ) / 2;
    my $half     = ( $y_max - $y_min ) / 2 * $factor;
    my $was_auto = $self->{y_auto};
    $self->{y_auto}        = 0;
    $self->{y_min_manual}  = $mid - $half;
    $self->{y_max_manual}  = $mid + $half;
    $self->{_render_state} = undef;
    if ( $was_auto && $self->{on_scale_mode_change} ) {
        $self->{on_scale_mode_change}->(0);
    }
    $self->request_render();
}

# Zoom vertical independiente del panel ATR
sub _vertical_drag_atr {
    my ($self, $dy) = @_;
    return unless defined $self->{atr_scale};
    my ($y_min, $y_max);
    if ( $self->{y_auto_atr} ) {
        $y_min = $self->{atr_scale}{y_min};
        $y_max = $self->{atr_scale}{y_max};
    } else {
        $y_min = $self->{y_min_atr};
        $y_max = $self->{y_max_atr};
    }
    my $range  = $y_max - $y_min;
    my $h      = $self->{atr_scale}{y_height} || 150;
    my $factor = 1 - $dy / $h;
    $factor = 0.1  if $factor < 0.1;
    $factor = 10.0 if $factor > 10.0;
    my $mid      = ( $y_max + $y_min ) / 2;
    my $new_half = ( $range / 2 ) * $factor;
    $self->{y_auto_atr}    = 0;
    $self->{y_min_atr}     = $mid - $new_half;
    $self->{y_max_atr}     = $mid + $new_half;
    $self->{_render_state} = undef;
    $self->request_render();
}

sub _vertical_zoom_atr {
    my ($self, $factor) = @_;
    return unless defined $self->{atr_scale};
    my ($y_min, $y_max);
    if ( $self->{y_auto_atr} ) {
        $y_min = $self->{atr_scale}{y_min};
        $y_max = $self->{atr_scale}{y_max};
    } else {
        $y_min = $self->{y_min_atr};
        $y_max = $self->{y_max_atr};
    }
    my $mid  = ( $y_max + $y_min ) / 2;
    my $half = ( $y_max - $y_min ) / 2 * $factor;
    $self->{y_auto_atr}    = 0;
    $self->{y_min_atr}     = $mid - $half;
    $self->{y_max_atr}     = $mid + $half;
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

    # Snap la linea vertical al centro de la barra mas cercana.
    # Clampear al rango de datos reales (no al virtual) para que en el espacio
    # vacio el crosshair siempre apunte a una vela existente.
    my $ix = $scale->x_to_index( $self->{crosshair_x} );
    my $lo = $scale->{data_start_index} // $scale->{start_index};
    $lo    = 0 if $lo < 0;
    my $hi = $self->{market}->last_index();
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

    # Recomputar SMC al cambiar timeframe (swing points cambian con cada TF)
    if ( $self->{_smc_indicator} ) {
        $self->{_smc_indicator}->reset();
        $self->{_smc_indicator}->compute_all( $self->{market} );
    }

    $self->reset_view();
}

sub reset_view {
    my ($self) = @_;
    $self->{visible_bars}  = 100;
    $self->{y_auto}        = 1;
    $self->{y_auto_atr}    = 1;
    $self->{_render_state} = undef;
    $self->{on_scale_mode_change}->(1) if $self->{on_scale_mode_change};
    $self->goto_last();
}

# Compute time labels for visible range (filtered to avoid overlap)
sub _nice_step_minutes {
    my ($self, $raw) = @_;
    my @steps = (1, 2, 3, 5, 10, 15, 20, 30, 60, 120, 180, 240, 360, 720, 1440, 4320, 10080);
    for my $s (@steps) {
        return $s if $raw <= $s;
    }
    return 10080;
}

my @_MESES = qw(Enero Febrero Marzo Abril Mayo Junio
                Julio Agosto Septiembre Octubre Noviembre Diciembre);

# Mapa de etiquetas legibles para cada clave de timeframe
my %_TF_LABEL = (
    '1'     => '1m',  '5'    => '5m',  '15'   => '15m',
    '60'    => '1h',  '120'  => '2h',  '240'  => '4h',
    '1440'  => 'D',   '10080'=> 'W',
);

sub tf_label {
    my ($self, $tf) = @_;
    $tf //= $self->{market}{current_tf} // '1';
    return $_TF_LABEL{$tf} // "${tf}m";
}

sub compute_intraday_labels {
    my ($self, $start, $end, $scale) = @_;
    my @labels;

    my $tf_min = $self->{market}{current_tf} || 1;
    $tf_min += 0;
    $tf_min = 1 if $tf_min <= 0;

    # --- Temporalidades D y W: una etiqueta de fecha por barra ---
    if ( $tf_min >= 1440 ) {
        my $prev_week = '';
        for my $i ($start .. $end) {
            my $ts = $self->{market}->get_timestamp($i);
            next unless defined $ts;
            my @lt = localtime($ts);
            my $label;
            if ( $tf_min >= 10080 ) {
                # Semanal: mostrar mes + dia del lunes
                my $week_key = sprintf("%04d-W%02d", $lt[5]+1900, int(($lt[7]+6)/7));
                next if $week_key eq $prev_week;
                $prev_week = $week_key;
                $label = $_MESES[$lt[4]] . ' ' . $lt[3];
            } else {
                $label = $_MESES[$lt[4]] . ' ' . $lt[3];
            }
            push @labels, { index => $i, label => $label, time => $ts };
        }
        return \@labels;
    }

    my $bar_w = 8;
    if ($scale && ($scale->{visible_bars} || 0) > 0) {
        $bar_w = $scale->{x_width} / $scale->{visible_bars};
    }

    my $target_px      = 90;
    my $bars_per_label = int($target_px / ($bar_w || 1) + 0.999);
    $bars_per_label = 1 if $bars_per_label < 1;

    my $step_min = $self->_nice_step_minutes($bars_per_label * $tf_min);
    my $step_sec = $step_min * 60;

    my $prev_bucket  = undef;
    my $prev_day_key = undef;

    for my $i ($start .. $end) {
        my $ts = $self->{market}->get_timestamp($i);
        next unless defined $ts;

        my @lt      = localtime($ts);
        my $hour    = $lt[2];
        my $min     = $lt[1];
        my $day_key = sprintf("%04d-%02d-%02d", $lt[5] + 1900, $lt[4] + 1, $lt[3]);

        # Para timeframes >= 1h los pivotes de 00:00 y 17:00 no aplican;
        # usar solo el cambio de dia como frontera principal.
        if ( $tf_min < 60 ) {
            # --- Pivote 1: Medianoche (00:00) ---
            if ($hour == 0 && $min == 0) {
                push @labels, { index=>$i, label=>$_MESES[$lt[4]].' '.$lt[3], time=>$ts };
                $prev_day_key = $day_key;
                $prev_bucket  = int($ts / $step_sec);
                next;
            }
            # --- Pivote 2: 17:00 apertura NQ ---
            if ($hour == 17 && $min == 0) {
                push @labels, { index => $i, label => '17:00', time => $ts };
                $prev_bucket = int($ts / $step_sec);
                next;
            }
        }

        # --- Frontera de dia (primer bar de un dia nuevo) ---
        if (!defined $prev_day_key || $day_key ne $prev_day_key) {
            $prev_day_key = $day_key;
            my $lbl = $tf_min >= 60
                ? $_MESES[$lt[4]] . ' ' . $lt[3]
                : $_MESES[$lt[4]] . ' ' . $lt[3] . sprintf(" %02d:%02d", $hour, $min);
            push @labels, { index => $i, label => $lbl, time => $ts };
            $prev_bucket = int($ts / $step_sec);
            next;
        }

        my $bucket = int($ts / $step_sec);
        next if defined $prev_bucket && $bucket == $prev_bucket;
        $prev_bucket = $bucket;

        my $label = $step_min < 60
            ? sprintf("%02d:%02d", $hour, $min)
            : sprintf("%02d:00", $hour);

        push @labels, { index => $i, label => $label, time => $ts };
    }

    return \@labels;
}

sub get_all_timestamps {
    my ($self) = @_;
    my ( $v_start, $v_end, $d_start, $d_end ) = $self->compute_window();
    return $self->compute_intraday_labels( $d_start, $d_end, $self->{price_scale} );
}

1;
