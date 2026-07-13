package Market::ChartEngine;

use strict;
use warnings;
use lib '.';
use Market::Panels::Scales;
use Market::Panels::PricePanel;
use Market::Panels::VolumePanel;
use Market::Panels::ATRPanel;

# Orchestrates the complete rendering pipeline.
# Coordinates panels, scales, and user events.
# No global variables; all state is encapsulated here.

my $TIME_AXIS_H = 30;   # pixels reserved at bottom of price canvas for time axis
my $RIGHT_SPACE_RATIO = 0.15;  # empty slots kept after the last visible candle

sub new {
    my ($class, %args) = @_;
    my $self = {
        market             => $args{market},
        indicators         => $args{indicators},
        price_canvas       => $args{price_canvas},
        price_scale_canvas => $args{price_scale_canvas},
        volume_canvas      => $args{volume_canvas},
        volume_scale_canvas => $args{volume_scale_canvas},
        atr_canvas         => $args{atr_canvas},
        atr_scale_canvas   => $args{atr_scale_canvas},

        visible_bars   => $args{visible_bars} // 100,
        offset         => 0,
        _offset_exact  => 0.0,
        _x_offset      => 0.0,
        y_auto         => 1,
        y_min_manual   => 0,
        y_max_manual   => 1,
        _price_scale_dragging => 0,
        _vy_drag_start        => undef,
        _vy_drag_y_min        => undef,
        _vy_drag_y_max        => undef,
        _vy_drag_height       => 1,

        crosshair_x       => undef,
        crosshair_y       => undef,
        _crosshair_source => 'price',
        pending_render    => 0,

        _drag_start_x      => undef,
        _drag_start_y      => undef,
        _drag_start_offset => 0,
        _drag_started_in_chart => 0,
        _drag_start_replay_index => undef,
        _drag_moved       => 0,
        _render_state      => undef,

        # Manual Fibonacci drawing tool
        manual_fib_selecting => 0,
        manual_fib_visible   => 1,
        manual_fib           => undef,
        manual_fib_preview   => undef,

        # Regression Channel drawing tool
        reg_channel_selecting => 0,    # 1 = modo seleccion activo (cursor crosshair)
        reg_channel_visible   => 1,    # toggle visibilidad
        reg_channel           => undef, # {from_index, to_index} — canal anclado
        reg_channel_preview   => undef, # preview durante el drag

        # --- Volume Profile manual drawing tool ---
        vp_selecting => 0,
        vp_preview   => undef,

        # --- Anchored VWAP manual tool ---
        vwap_selecting => 0,

        on_scale_mode_change => undef,

        # --- Overlays SMC y Liquidez ---
        overlays        => [],   # lista de objetos overlay
        _lq_indicator   => undef,  # Market::Indicators::Liquidity

        # --- Sistema Replay ---
        replay_mode    => 0,       # 1 = en modo replay
        replay_selecting => 0,     # 1 = boton Replay armado para elegir vela inicial
        replay_cursor  => undef,   # indice de la ultima vela visible (barrera temporal)
        selected_replay_index => undef, # ultima vela seleccionada dentro de Replay
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
        volume_panel => undef,
        atr_panel   => undef,
        price_scale => undef,
        volume_scale => undef,
        atr_scale   => undef,
    };
    bless $self, $class;

    $self->{price_panel} = Market::Panels::PricePanel->new(
        canvas       => $self->{price_canvas},
        scale_canvas => $self->{price_scale_canvas},
    );
    $self->{volume_panel} = Market::Panels::VolumePanel->new(
        canvas       => $self->{volume_canvas},
        scale_canvas => $self->{volume_scale_canvas},
    );
    $self->{atr_panel} = Market::Panels::ATRPanel->new(
        canvas       => $self->{atr_canvas},
        scale_canvas => $self->{atr_scale_canvas},
    );

    return $self;
}

sub _right_space_bars {
    my ($self, $bars) = @_;
    my $n = $bars || $self->{visible_bars} || 100;
    my $pad = int( $n * $RIGHT_SPACE_RATIO + 0.5 );
    $pad = 1 if $pad < 1;
    $pad = $n - 1 if $pad >= $n;
    return $pad;
}

sub _offset_for_index_with_right_space {
    my ($self, $index, $bars) = @_;
    return $self->{market}->last_index() - $index - $self->_right_space_bars($bars);
}

# Calcula la ventana virtual y los indices de datos reales visibles.
# Retorna: (v_start, v_end, d_start, d_end)
#   v_start/v_end = indices virtuales (pueden ser negativos o > last para espacio vacio)
#   d_start/d_end = indices reales con datos, clampeados al historico permitido
# Cuando v_start < 0 se ve espacio vacio a la izquierda (antes de la primera vela).
# Cuando v_end > last se ve espacio vacio a la derecha (despues de la ultima vela).
sub compute_window {
    my ($self) = @_;
    my $last    = $self->{market}->last_index();
    my $n       = $self->{visible_bars};

    my $data_end_limit = $last;
    if ( $self->{replay_mode} && defined $self->{replay_cursor} ) {
        $self->{replay_cursor} = 0     if $self->{replay_cursor} < 0;
        $self->{replay_cursor} = $last if $self->{replay_cursor} > $last;
        $data_end_limit = $self->{replay_cursor};
    }

    my $v_end   = $last - $self->{offset};
    my $v_start = $v_end - $n + 1;

    my $d_start = $v_start < 0     ? 0     : $v_start;
    my $d_end   = $v_end   > $data_end_limit ? $data_end_limit : $v_end;

    # Rango vacio cuando la ventana esta completamente fuera de los datos
    if ( $d_end < 0 || $d_start > $data_end_limit ) {
        $d_end = $d_start - 1;
    }

    return ( $v_start, $v_end, $d_start, $d_end );
}

# Ancla explicitamente la ultima vela historica dejando espacio vacio a la derecha.
# Llamado por reset_view y por el atajo de teclado End.
sub goto_last {
    my ($self) = @_;
    if ( $self->{replay_mode} && defined $self->{replay_cursor} ) {
        $self->_anchor_cursor_to_right_edge();
        $self->{_render_state} = undef;
        $self->request_render();
        return;
    }

    my $new_off = $self->_offset_for_index_with_right_space( $self->{market}->last_index() );
    $self->{offset}        = $new_off;
    $self->{_offset_exact} = $new_off * 1.0;
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
    for my $cv ( $self->{price_canvas}, $self->{volume_canvas}, $self->{atr_canvas} ) {
        my $w = $cv->width()  || 1;
        my $h = $cv->height() || 1;
        $cv->configure( -scrollregion => [ 0, 0, $w, $h ] );
    }

    # v_start/v_end = ventana virtual (puede salir del rango de datos -> espacio vacio)
    # d_start/d_end = indices reales con datos dentro del historico permitido
    my ( $v_start, $v_end, $d_start, $d_end ) = $self->compute_window();
    my $data_slice = $d_end >= $d_start
        ? $self->{market}->get_slice( $d_start, $d_end )
        : [];
    return unless @$data_slice;

    my $n_visible = $self->{visible_bars};   # siempre el ancho completo de la ventana
    my $pw = $self->{price_canvas}->width()  || 900;
    my $ph = $self->{price_canvas}->height() || 500;
    my $vw = $self->{volume_canvas}->width() || 900;
    my $vh = $self->{volume_canvas}->height() || 90;
    my $aw = $self->{atr_canvas}->width()    || 900;
    my $ah = $self->{atr_canvas}->height()   || 150;
    my $volume_max = $self->{volume_panel}->get_volume_max($data_slice);

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

    # Volume scale — panel independiente, misma ventana horizontal
    my $volume_scale = Market::Panels::Scales->new(
        x_left       => 0,
        x_width      => $vw,
        start_index  => $v_start,
        visible_bars => $n_visible,
        y_top        => 0,
        y_height     => $vh,
        y_min        => 0,
        y_max        => 1,
    );
    $volume_scale->{data_start_index} = $d_start;
    my ( $v_min, $v_max ) = $self->{volume_panel}->get_y_range($data_slice);
    $volume_scale->{y_min} = $v_min;
    $volume_scale->{y_max} = $v_max;
    $volume_scale->{x_offset} = $self->{_x_offset} // 0;
    $self->{volume_scale} = $volume_scale;

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
    if ( $rs && $self->_can_incremental( $rs, $v_start, $v_end, $d_start, $d_end, $price_scale, $n_visible, $pw, $ph, $vw, $vh, $volume_max ) ) {
        $self->_incremental_pan( $v_start, $v_end, $d_start, $d_end, $data_slice, $price_scale, $volume_scale, $atr_slice, $atr_scale, $rs, $volume_max );
    }
    else {
        $self->_full_render( $d_start, $d_end, $data_slice, $price_scale, $volume_scale, $atr_slice, $atr_scale, $volume_max );
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
        volume_max   => $volume_max,
        pw           => $pw,
        ph           => $ph,
        vw           => $vw,
        vh           => $vh,
    };

    if ( defined $self->{crosshair_x} ) {
        $self->_draw_crosshair_all();
    }
}

# Returns true when an incremental pan is safe (no Y rescale, no zoom, no resize)
sub _can_incremental {
    my ($self, $rs, $v_start, $v_end, $d_start, $d_end, $pscale, $n_visible, $pw, $ph, $vw, $vh, $volume_max) = @_;

    return 0 if $self->{_x_offset} != 0;
    return 0 if $rs->{pw} != $pw || $rs->{ph} != $ph;
    return 0 if ($rs->{vw}//0) != $vw || ($rs->{vh}//0) != $vh;
    return 0 if $rs->{visible_bars} != $n_visible;
    return 0 if ( $rs->{volume_max} // 0 ) != ( $volume_max // 0 );

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

sub _raise_overlay_labels {
    my ($self, $canvas) = @_;
    return unless $canvas;

    $canvas->raise('lq_label')       if $canvas->find( 'withtag', 'lq_label' );
    $canvas->raise('smc_label')      if $canvas->find( 'withtag', 'smc_label' );
    $canvas->raise('strategy_label') if $canvas->find( 'withtag', 'strategy_label' );
    $canvas->raise('vp_label')       if $canvas->find( 'withtag', 'vp_label' );
    $canvas->raise('vwap_label')     if $canvas->find( 'withtag', 'vwap_label' );
}

# Complete redraw of all panels and scales
sub _full_render {
    my ($self, $d_start, $d_end, $data_slice, $pscale, $vscale, $atr_slice, $ascale, $volume_max) = @_;

    my $pc  = $self->{price_canvas};
    my $psc = $self->{price_scale_canvas};
    my $vc  = $self->{volume_canvas};
    my $vsc = $self->{volume_scale_canvas};
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
    $self->_render_regression_channel( $pc, $pscale, $cur_bar );
    $self->_render_manual_fibonacci( $pc, $pscale, $cur_bar );
    $self->_draw_replay_marker( $pc, $d_start, $d_end, $pscale );
    $self->_raise_overlay_labels($pc);

    # --- Price scale (must come after candles so lastprice draws on ready canvas) ---
    $psc->delete('all');
    $pscale->_draw_y_scale($psc);
    $self->{price_panel}->render_last_visible_price($pc);

    # --- Volume panel ---
    $vc->delete('all');
    $self->{volume_panel}->set_scale($vscale);
    $self->{volume_panel}->render( $vc, $data_slice, $vscale );
    $self->{volume_panel}->render_scale($vsc);

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
    my ($self, $v_start, $v_end, $d_start, $d_end, $data_slice, $pscale, $vscale, $atr_slice, $ascale, $rs, $volume_max) = @_;

    # El delta virtual determina cuantos pixeles se desplazan las velas existentes
    my $delta = $v_start - $rs->{v_start};
    my $bar_w = $pscale->{x_width} / ( $pscale->{visible_bars} || 1 );
    my $dx    = -$delta * $bar_w;

    my $pc  = $self->{price_canvas};
    my $psc = $self->{price_scale_canvas};
    my $vc  = $self->{volume_canvas};
    my $vsc = $self->{volume_scale_canvas};
    my $ac  = $self->{atr_canvas};
    my $asc = $self->{atr_scale_canvas};

    $self->{price_panel}->set_scale($pscale);
    $self->{volume_panel}->set_scale($vscale);
    $self->{atr_panel}->set_scale($ascale);

    # Shift all price items O(1)
    $pc->move( 'candles', $dx, 0 );

    if ( $delta > 0 ) {
        # Panned left: eliminar velas que salieron por la izquierda, agregar a la derecha
        $pc->delete("ci_$_") for $rs->{d_start} .. $d_start - 1;
        for my $i ( 0 .. $#$data_slice ) {
            my $ix = $d_start + $i;
            next unless $ix > $rs->{d_end};
            $self->{price_panel}->render_candle( $pc, $data_slice->[$i], $ix, $pscale );
        }
    }
    else {
        # Panned right: eliminar velas que salieron por la derecha, agregar a la izquierda
        $pc->delete("ci_$_") for ( $d_end + 1 ) .. $rs->{d_end};
        for my $i ( 0 .. $#$data_slice ) {
            my $ix = $d_start + $i;
            next unless $ix < $rs->{d_start};
            $self->{price_panel}->render_candle( $pc, $data_slice->[$i], $ix, $pscale );
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
    $self->_render_regression_channel( $pc, $pscale, $cur_bar2 );
    $self->_render_manual_fibonacci( $pc, $pscale, $cur_bar2 );
    $self->_draw_replay_marker( $pc, $d_start, $d_end, $pscale );
    $self->_raise_overlay_labels($pc);

    # Redraw last price label
    $pc->delete('lastprice');
    $psc->delete('all');
    $pscale->_draw_y_scale($psc);
    $self->{price_panel}->render_last_visible_price($pc);

    # Redraw volume panel independently from price overlays
    $vc->delete('all');
    $self->{volume_panel}->render( $vc, $data_slice, $vscale );
    $self->{volume_panel}->render_scale($vsc);

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
    $vc->raise('crosshair');
    $ac->raise('crosshair');
}

# Bind all user input events
sub bind_events {
    my ($self) = @_;
    $self->_bind_all_canvas( $self->{price_canvas} );
    $self->_bind_all_canvas( $self->{volume_canvas} );
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
    $psc->configure( -cursor => 'sb_v_double_arrow' );

    $psc->bind( '<ButtonPress-1>', sub {
        $self->_price_scale_drag_start( $psc->pointery() );
        return Tk::break();   # impide que MainWindow procese este click como pan horizontal
    });

    $psc->bind( '<B1-Motion>', sub {
        $self->_price_scale_drag_to( $psc->pointery() );
        return Tk::break();
    });

    $psc->bind( '<ButtonRelease-1>', sub {
        $self->_price_scale_drag_end();
        return Tk::break();
    });

    # Rueda del mouse sobre escala Y → zoom vertical (no horizontal)
    # Button-4 = scroll arriba = zoom IN (rango mas chico, velas mas grandes)
    # Button-5 = scroll abajo  = zoom OUT (rango mas grande, velas mas chicas)
    $psc->bind( '<Button-4>', sub { $self->_vertical_zoom(0.85);     return Tk::break() });
    $psc->bind( '<Button-5>', sub { $self->_vertical_zoom(1 / 0.85); return Tk::break() });

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

    # Zoom normal (sin Ctrl): ajusta visible_bars manteniendo el rango horizontal actual
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
    my $vc = $self->{volume_canvas};
    my $ac = $self->{atr_canvas};

    my $pcx = $rx - $pc->rootx;
    my $pcy = $ry - $pc->rooty;
    if ( $pcx >= 0 && $pcx < ( $pc->width || 900 )
      && $pcy >= 0 && $pcy < ( $pc->height || 500 ) ) {
        $self->_on_mouse_move_xy( $pcx, $pcy, 'price' );
        return;
    }

    my $vcx = $rx - $vc->rootx;
    my $vcy = $ry - $vc->rooty;
    if ( $vcx >= 0 && $vcx < ( $vc->width || 900 )
      && $vcy >= 0 && $vcy < ( $vc->height || 90 ) ) {
        $self->_on_mouse_move_xy( $vcx, $vcy, 'volume' );
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
    $self->{volume_panel}->hide_crosshair();
    $self->{atr_panel}->hide_crosshair();
}

sub _point_in_widget {
    my ($self, $w, $root_x, $root_y) = @_;
    return 0 unless $w && defined $root_x && defined $root_y;

    my $x = $root_x - $w->rootx;
    my $y = $root_y - $w->rooty;
    my $ww = $w->width  || 0;
    my $hh = $w->height || 0;

    return $x >= 0 && $x < $ww && $y >= 0 && $y < $hh;
}

sub _index_from_global_point {
    my ($self, $global_x, $global_y) = @_;
    return unless defined $global_x && defined $global_y;

    my ($canvas, $scale);
    if ( $self->_point_in_widget( $self->{price_canvas}, $global_x, $global_y ) ) {
        ($canvas, $scale) = ( $self->{price_canvas}, $self->{price_scale} );
    }
    elsif ( $self->_point_in_widget( $self->{volume_canvas}, $global_x, $global_y ) ) {
        ($canvas, $scale) = ( $self->{volume_canvas}, $self->{volume_scale} );
    }
    elsif ( $self->_point_in_widget( $self->{atr_canvas}, $global_x, $global_y ) ) {
        ($canvas, $scale) = ( $self->{atr_canvas}, $self->{atr_scale} );
    }
    return unless $canvas && $scale;

    my $x  = $global_x - $canvas->rootx;
    my $ix = $scale->x_to_index($x);
    my ( undef, undef, $d_start, $d_end ) = $self->compute_window();
    my $hi = $self->{replay_mode} && defined $self->{replay_cursor}
        ? $self->{replay_cursor}
        : $d_end;
    my $last = $self->{market}->last_index();
    $d_start = 0 if $d_start < 0;
    $hi = $last if $hi > $last;
    $ix = $d_start if $ix < $d_start;
    $ix = $hi      if $ix > $hi;
    return undef if $ix < 0 || $ix > $last;
    return $ix;
}

sub set_replay_start_index {
    my ($self, $index) = @_;
    return unless $self->{replay_mode} || $self->{replay_selecting};
    return unless defined $index;
    my $last = $self->{market}->last_index();
    return if $last < 0;
    $index = 0     if $index < 0;
    $index = $last if $index > $last;

    $self->{selected_replay_index} = $index;
    if ( $self->{replay_selecting} && !$self->{replay_mode} ) {
        $self->start_replay($index);
        return;
    }

    $self->pause_replay() if $self->{replay_playing};
    $self->{replay_cursor} = $index;
    $self->_anchor_cursor_to_right_edge();
    $self->{_render_state} = undef;
    $self->request_render();
}

sub _price_scale_drag_start {
    my ($self, $root_y) = @_;
    return unless $self->{price_scale};

    my $scale = $self->{price_scale};
    my $y_min = $self->{y_auto} ? $scale->{y_min} : $self->{y_min_manual};
    my $y_max = $self->{y_auto} ? $scale->{y_max} : $self->{y_max_manual};
    return unless defined $y_min && defined $y_max && $y_max > $y_min;

    my $was_auto = $self->{y_auto};
    $self->{y_auto}              = 0;
    $self->{_price_scale_dragging} = 1;
    $self->{_vy_drag_start}      = $root_y;
    $self->{_vy_drag_y_min}      = $y_min;
    $self->{_vy_drag_y_max}      = $y_max;
    $self->{_vy_drag_height}     = $scale->{y_height} || 1;
    $self->{y_min_manual}        = $y_min;
    $self->{y_max_manual}        = $y_max;
    $self->{_render_state}       = undef;

    $self->{price_scale_canvas}->configure( -cursor => 'sb_v_double_arrow' )
        if $self->{price_scale_canvas};
    $self->{on_scale_mode_change}->(0)
        if $was_auto && $self->{on_scale_mode_change};
}

sub _price_scale_drag_to {
    my ($self, $root_y) = @_;
    return unless $self->{_price_scale_dragging};

    my $start = $self->{_vy_drag_start} // $root_y;
    my $dy    = $root_y - $start;
    my $h     = $self->{_vy_drag_height} || 1;

    my $base_min = $self->{_vy_drag_y_min};
    my $base_max = $self->{_vy_drag_y_max};
    return unless defined $base_min && defined $base_max && $base_max > $base_min;

    my $center = ($base_min + $base_max) / 2;
    my $range  = $base_max - $base_min;

    # dy > 0 estira las velas; dy < 0 comprime. El exponencial evita cambios bruscos.
    my $factor = exp( -2.0 * $dy / $h );
    $factor = 0.02 if $factor < 0.02;
    $factor = 50.0 if $factor > 50.0;

    my $half = ($range * $factor) / 2;
    my $min_half = abs($center) * 1e-10;
    $min_half = 1e-8 if $min_half < 1e-8;
    $half = $min_half if $half < $min_half;

    $self->{y_min_manual}  = $center - $half;
    $self->{y_max_manual}  = $center + $half;
    $self->{_render_state} = undef;
    $self->{pending_render} = 0;
    $self->render();
}

sub _price_scale_drag_end {
    my ($self) = @_;
    $self->{_price_scale_dragging} = 0;
    $self->{_vy_drag_start}  = undef;
    $self->{_vy_drag_y_min}  = undef;
    $self->{_vy_drag_y_max}  = undef;
    $self->{_vy_drag_height} = 1;
    $self->{price_scale_canvas}->configure( -cursor => 'sb_v_double_arrow' )
        if $self->{price_scale_canvas};
}

sub _manual_fib_point_from_global {
    my ($self, $global_x, $global_y) = @_;
    my $pc    = $self->{price_canvas};
    my $scale = $self->{price_scale};
    return unless $pc && $scale;

    my $x = $global_x - $pc->rootx;
    my $y = $global_y - $pc->rooty;
    my $w = $pc->width  || 900;
    my $h = $scale->{y_height} || ($pc->height || 500);
    return if $x < 0 || $x > $w || $y < 0 || $y > $h;

    my $ix = $scale->x_to_index($x);
    my ( undef, undef, $d_start, $d_end ) = $self->compute_window();
    my $hi = $self->{replay_mode} && defined $self->{replay_cursor}
        ? $self->{replay_cursor}
        : $d_end;
    $ix = $d_start if $ix < $d_start;
    $ix = $hi      if $ix > $hi;

    $y = 0  if $y < 0;
    $y = $h if $y > $h;

    return {
        index => $ix,
        price => $scale->y_to_value($y),
    };
}

sub _set_manual_fib_cursor {
    my ($self) = @_;
    return unless $self->{price_canvas};
    my $cursor = $self->{manual_fib_selecting} ? 'crosshair' : 'arrow';
    $self->{price_canvas}->configure( -cursor => $cursor );
}

sub start_manual_fibonacci_selection {
    my ($self) = @_;
    $self->{manual_fib_selecting} = 1;
    $self->{manual_fib_preview}   = undef;
    $self->_set_manual_fib_cursor();
}

sub set_manual_fibonacci_visible {
    my ($self, $visible) = @_;
    $self->{manual_fib_visible} = $visible ? 1 : 0;
    $self->{_render_state} = undef;
    $self->request_render();
}

sub clear_manual_fibonacci {
    my ($self) = @_;
    $self->{manual_fib}           = undef;
    $self->{manual_fib_preview}   = undef;
    $self->{manual_fib_selecting} = 0;
    $self->_set_manual_fib_cursor();
    $self->{price_canvas}->delete('manual_fib')         if $self->{price_canvas};
    $self->{price_canvas}->delete('manual_fib_preview') if $self->{price_canvas};
    $self->{_render_state} = undef;
    $self->request_render();
}

sub _manual_fib_start {
    my ($self, $global_x, $global_y) = @_;
    my $pt = $self->_manual_fib_point_from_global($global_x, $global_y);
    return unless $pt;
    $self->{manual_fib_preview} = {
        from => { %$pt },
        to   => { %$pt },
    };
    $self->{price_canvas}->delete('manual_fib_preview');
    $self->_draw_manual_fib_set( $self->{price_canvas}, $self->{price_scale},
        $self->{manual_fib_preview}, 'manual_fib_preview', 1 );
}

sub _manual_fib_drag_to {
    my ($self, $global_x, $global_y) = @_;
    return unless $self->{manual_fib_preview};
    my $pt = $self->_manual_fib_point_from_global($global_x, $global_y);
    return unless $pt;
    $self->{manual_fib_preview}{to} = { %$pt };
    $self->{price_canvas}->delete('manual_fib_preview');
    $self->_draw_manual_fib_set( $self->{price_canvas}, $self->{price_scale},
        $self->{manual_fib_preview}, 'manual_fib_preview', 1 );
}

sub _manual_fib_finish {
    my ($self) = @_;
    my $fib = $self->{manual_fib_preview};
    $self->{manual_fib_preview}   = undef;
    $self->{manual_fib_selecting} = 0;
    $self->_set_manual_fib_cursor();
    $self->{price_canvas}->delete('manual_fib_preview') if $self->{price_canvas};

    if ($fib) {
        my $di = abs( $fib->{to}{index} - $fib->{from}{index} );
        my $dp = abs( $fib->{to}{price} - $fib->{from}{price} );
        if ( $di >= 1 && $dp > 0.000001 ) {
            $self->{manual_fib} = $fib;
            $self->{manual_fib_visible} = 1;
        }
    }

    $self->{_render_state} = undef;
    $self->request_render();
}

sub _render_manual_fibonacci {
    my ($self, $canvas, $scale, $current_bar) = @_;
    $canvas->delete('manual_fib');
    return unless $self->{manual_fib_visible};
    return unless $self->{manual_fib};
    $self->_draw_manual_fib_set( $canvas, $scale, $self->{manual_fib}, 'manual_fib', 0, $current_bar );
}

sub _draw_manual_fib_set {
    my ($self, $canvas, $scale, $fib, $tag, $is_preview, $current_bar) = @_;
    return unless $canvas && $scale && $fib && $fib->{from} && $fib->{to};

    my $i0 = $fib->{from}{index};
    my $i1 = $fib->{to}{index};
    my $p0 = $fib->{from}{price};
    my $p1 = $fib->{to}{price};
    return unless defined $i0 && defined $i1 && defined $p0 && defined $p1;
    return if defined $current_bar && ( $i0 > $current_bar || $i1 > $current_bar );

    my $x0 = $scale->index_to_center_x($i0);
    my $x1 = $scale->index_to_center_x($i1);
    my $left  = $x0 < $x1 ? $x0 : $x1;
    my $right = $x0 < $x1 ? $x1 : $x0;
    return if $right < 0 || $left > $scale->{x_width};

    my $draw_left  = $left  < 0 ? 0 : $left;
    my $draw_right = $right > $scale->{x_width} ? $scale->{x_width} : $right;
    return if $draw_right <= $draw_left;

    my $y0 = $scale->value_to_y($p0);
    my $y1 = $scale->value_to_y($p1);
    my $ytop = $y0 < $y1 ? $y0 : $y1;
    my $ybot = $y0 < $y1 ? $y1 : $y0;
    my $vh = $scale->{y_height} || 1;
    my $zone_top = $ytop < 0 ? 0 : $ytop;
    my $zone_bot = $ybot > $vh ? $vh : $ybot;

    my @tags = ($tag);
    my $line_color = $is_preview ? '#d7dee9' : '#9aa5b5';
    my $gold = '#d6b84f';

    if ( $zone_bot > $zone_top ) {
        $canvas->createRectangle( $draw_left, $zone_top, $draw_right, $zone_bot,
            -fill => '#2f4051', -outline => '#2f4051',
            -stipple => $is_preview ? 'gray12' : 'gray25',
            -tags => \@tags,
        );
    }

    $canvas->createLine( $x0, $y0, $x1, $y1,
        -fill => $line_color, -width => 1, -dash => [4, 3], -tags => \@tags,
    );

    for my $pt ( [$x0, $y0], [$x1, $y1] ) {
        $canvas->createOval( $pt->[0] - 4, $pt->[1] - 4, $pt->[0] + 4, $pt->[1] + 4,
            -outline => $line_color, -width => 1, -tags => \@tags,
        );
    }

    my @levels = (0, 0.236, 0.382, 0.5, 0.618, 0.786, 1, 1.272, 1.618, 2.236);
    for my $ratio (@levels) {
        my $price = $p0 + ($p1 - $p0) * $ratio;
        my $y = $scale->value_to_y($price);
        next if $y < -20 || $y > $vh + 20;
        my $color = ($ratio == 0.5 || $ratio == 0.618) ? $gold : $line_color;
        my $dash = ($ratio == 0 || $ratio == 1) ? undef : [2, 3];

        my %line_opts = (
            -fill => $color,
            -width => ($ratio == 0 || $ratio == 1 || $ratio == 0.618) ? 1.5 : 1,
            -tags => \@tags,
        );
        $line_opts{-dash} = $dash if $dash;
        $canvas->createLine( $draw_left, $y, $draw_right, $y, %line_opts );

        my $label = sprintf('%.3g  %.2f', $ratio, $price);
        my $font = $ratio == 0.618 ? ['Helvetica', 7, 'bold'] : ['Helvetica', 7];
        $canvas->createText( $draw_right - 4, $y - 6,
            -text => $label, -fill => $color,
            -font => $font,
            -anchor => 'e', -tags => \@tags,
        );
    }
}

# ================================================================
# REGRESSION CHANNEL — Herramienta de dibujo interactiva
# ================================================================
# Calcula regresion lineal + desviacion estandar sobre un rango
# de velas seleccionado por el usuario via click-drag.
# El canal queda anclado a los indices de inicio/fin.
# ================================================================

sub _reg_channel_index_from_global {
    my ($self, $global_x, $global_y) = @_;
    my $pc    = $self->{price_canvas};
    my $scale = $self->{price_scale};
    return unless $pc && $scale;

    my $x = $global_x - $pc->rootx;
    my $y = $global_y - $pc->rooty;
    my $w = $pc->width  || 900;
    my $h = $scale->{y_height} || ($pc->height || 500);
    return if $x < 0 || $x > $w || $y < 0 || $y > $h;

    my $ix = $scale->x_to_index($x);
    my ( undef, undef, $d_start, $d_end ) = $self->compute_window();
    my $hi = $self->{replay_mode} && defined $self->{replay_cursor}
        ? $self->{replay_cursor}
        : $d_end;
    my $last = $self->{market}->last_index();
    $ix = 0     if $ix < 0;
    $ix = $hi   if $ix > $hi;
    $ix = $last if $ix > $last;
    return $ix;
}

sub _set_reg_channel_cursor {
    my ($self) = @_;
    return unless $self->{price_canvas};
    my $cursor = $self->{reg_channel_selecting} ? 'crosshair' : 'arrow';
    $self->{price_canvas}->configure( -cursor => $cursor );
}

sub start_regression_channel_selection {
    my ($self) = @_;
    $self->{reg_channel_selecting} = 1;
    $self->{reg_channel_preview}   = undef;
    $self->{vp_selecting} = 0;
    $self->{vwap_selecting} = 0;
    $self->_set_reg_channel_cursor();
}

sub start_vp_selection {
    my ($self) = @_;
    $self->{reg_channel_selecting} = 0;
    $self->{vwap_selecting} = 0;
    $self->{vp_selecting} = 1;
    $self->{vp_preview} = undef;
    $self->{price_canvas}->configure(-cursor => 'crosshair') if $self->{price_canvas};
}

sub clear_vp {
    my ($self) = @_;
    $self->{vp_selecting} = 0;
    $self->{vp_preview} = undef;
    $self->{price_canvas}->configure(-cursor => 'arrow') if $self->{price_canvas};
    my $ind = $self->{indicators}->get('VolumeProfile') if $self->{indicators};
    if ($ind) {
        $ind->clear_manual_anchors();
        $ind->compute_all($self->{market});
        $self->{_render_state} = undef;
        $self->request_render();
    }
}

sub start_vwap_selection {
    my ($self) = @_;
    $self->{reg_channel_selecting} = 0;
    $self->{vp_selecting} = 0;
    $self->{vwap_selecting} = 1;
    $self->{price_canvas}->configure(-cursor => 'crosshair') if $self->{price_canvas};
}

sub clear_vwap {
    my ($self) = @_;
    $self->{vwap_selecting} = 0;
    $self->{price_canvas}->configure(-cursor => 'arrow') if $self->{price_canvas};
    my $ind = $self->{indicators}->get('AnchoredVWAP') if $self->{indicators};
    if ($ind) {
        $ind->clear_manual_anchors();
        $ind->compute_all($self->{market});
        $self->{_render_state} = undef;
        $self->request_render();
    }
}

sub set_regression_channel_visible {
    my ($self, $visible) = @_;
    $self->{reg_channel_visible} = $visible ? 1 : 0;
    $self->{_render_state} = undef;
    $self->request_render();
}

sub clear_regression_channel {
    my ($self) = @_;
    $self->{reg_channel}           = undef;
    $self->{reg_channel_preview}   = undef;
    $self->{reg_channel_selecting} = 0;
    $self->_set_reg_channel_cursor();
    $self->{price_canvas}->delete('reg_channel')         if $self->{price_canvas};
    $self->{price_canvas}->delete('reg_channel_preview') if $self->{price_canvas};
    $self->{_render_state} = undef;
    $self->request_render();
}

sub _reg_channel_start {
    my ($self, $global_x, $global_y) = @_;
    my $ix = $self->_reg_channel_index_from_global($global_x, $global_y);
    return unless defined $ix;
    $self->{reg_channel_preview} = {
        from_index => $ix,
        to_index   => $ix,
    };
    $self->{price_canvas}->delete('reg_channel_preview');
}

sub _reg_channel_drag_to {
    my ($self, $global_x, $global_y) = @_;
    return unless $self->{reg_channel_preview};
    my $ix = $self->_reg_channel_index_from_global($global_x, $global_y);
    return unless defined $ix;
    $self->{reg_channel_preview}{to_index} = $ix;
    $self->{price_canvas}->delete('reg_channel_preview');
    $self->_draw_regression_channel_set(
        $self->{price_canvas}, $self->{price_scale},
        $self->{reg_channel_preview}, 'reg_channel_preview', 1,
    );
}

sub _reg_channel_finish {
    my ($self) = @_;
    my $ch = $self->{reg_channel_preview};
    $self->{reg_channel_preview}   = undef;
    $self->{reg_channel_selecting} = 0;
    $self->_set_reg_channel_cursor();
    $self->{price_canvas}->delete('reg_channel_preview') if $self->{price_canvas};

    if ($ch) {
        my $di = abs( $ch->{to_index} - $ch->{from_index} );
        if ( $di >= 2 ) {
            $self->{reg_channel} = $ch;
            $self->{reg_channel_visible} = 1;
        }
    }

    $self->{_render_state} = undef;
    $self->request_render();
}

sub _render_regression_channel {
    my ($self, $canvas, $scale, $current_bar) = @_;
    $canvas->delete('reg_channel');
    return unless $self->{reg_channel_visible};
    return unless $self->{reg_channel};
    $self->_draw_regression_channel_set(
        $canvas, $scale,
        $self->{reg_channel}, 'reg_channel', 0, $current_bar,
    );
}

# Calcula regresion lineal y desviacion estandar, luego dibuja:
#   - Poligono superior (azul semitransparente)
#   - Poligono inferior (rojo semitransparente)
#   - Linea central de regresion (solida)
#   - Limites superior/inferior a +/-1 sigma (dashed)
#   - Manejadores circulares en los extremos
sub _draw_regression_channel_set {
    my ($self, $canvas, $scale, $ch, $tag, $is_preview, $current_bar) = @_;
    return unless $canvas && $scale && $ch;
    return unless defined $ch->{from_index} && defined $ch->{to_index};

    my $i0 = $ch->{from_index};
    my $i1 = $ch->{to_index};
    # Normalizar: i_start siempre <= i_end
    my $i_start = $i0 < $i1 ? $i0 : $i1;
    my $i_end   = $i0 < $i1 ? $i1 : $i0;
    return if $i_end - $i_start < 2;   # necesitamos al menos 3 puntos

    # Limitar al current_bar en modo replay
    if ( defined $current_bar ) {
        return if $i_start > $current_bar;
        $i_end = $current_bar if $i_end > $current_bar;
    }

    # Limitar al rango de datos disponible
    my $last = $self->{market}->last_index();
    $i_start = 0     if $i_start < 0;
    $i_end   = $last  if $i_end > $last;
    return if $i_end - $i_start < 2;

    # ---- Obtener precios de cierre para el rango ----
    my $data_slice = $self->{market}->get_slice($i_start, $i_end);
    return unless $data_slice && @$data_slice >= 3;

    my $N = scalar @$data_slice;

    # ---- Regresion lineal: y = a + b*x ----
    # x = posicion relativa (0..N-1), y = close
    my ($sum_x, $sum_y, $sum_xy, $sum_x2) = (0, 0, 0, 0);
    for my $j (0 .. $N - 1) {
        my $close = $data_slice->[$j]{close};
        $sum_x  += $j;
        $sum_y  += $close;
        $sum_xy += $j * $close;
        $sum_x2 += $j * $j;
    }

    my $denom = $N * $sum_x2 - $sum_x * $sum_x;
    return if abs($denom) < 1e-12;

    my $b = ($N * $sum_xy - $sum_x * $sum_y) / $denom;
    my $a = ($sum_y - $b * $sum_x) / $N;

    # ---- Desviacion maxima real usando High y Low ----
    # En lugar de sigma simetrica sobre close, calculamos la maxima distancia
    # que cualquier High queda POR ENCIMA de la recta y cualquier Low queda
    # POR DEBAJO. Esto garantiza que el canal envuelva todas las mechas.
    my $max_dev_up   = 0;   # max(high_j - predicted_j)
    my $max_dev_down = 0;   # max(predicted_j - low_j)
    for my $j (0 .. $N - 1) {
        my $predicted = $a + $b * $j;
        my $dev_up   = $data_slice->[$j]{high} - $predicted;
        my $dev_down = $predicted - $data_slice->[$j]{low};
        $max_dev_up   = $dev_up   if $dev_up   > $max_dev_up;
        $max_dev_down = $dev_down if $dev_down > $max_dev_down;
    }

    # ---- Coordenadas de pantalla para los extremos ----
    my $x_left  = $scale->index_to_center_x($i_start);
    my $x_right = $scale->index_to_center_x($i_end);
    return if $x_right < 0 || $x_left > $scale->{x_width};

    # Precio en los extremos de la linea central
    my $p_left  = $a;                        # x=0
    my $p_right = $a + $b * ($N - 1);        # x=N-1

    # Limites: la banda superior usa max_dev_up, la inferior usa max_dev_down
    my $p_upper_left  = $p_left  + $max_dev_up;
    my $p_upper_right = $p_right + $max_dev_up;
    my $p_lower_left  = $p_left  - $max_dev_down;
    my $p_lower_right = $p_right - $max_dev_down;

    # Convertir a coordenadas Y de pantalla
    my $y_center_l = $scale->value_to_y($p_left);
    my $y_center_r = $scale->value_to_y($p_right);
    my $y_upper_l  = $scale->value_to_y($p_upper_left);
    my $y_upper_r  = $scale->value_to_y($p_upper_right);
    my $y_lower_l  = $scale->value_to_y($p_lower_left);
    my $y_lower_r  = $scale->value_to_y($p_lower_right);

    my @tags = ($tag);
    my $blue = '#2962ff';
    my $red  = '#ef5350';
    my $stipple = $is_preview ? 'gray12' : 'gray25';

    # ---- Poligono superior: central → +1σ (azul) ----
    $canvas->createPolygon(
        $x_left,  $y_center_l,
        $x_right, $y_center_r,
        $x_right, $y_upper_r,
        $x_left,  $y_upper_l,
        -fill    => $blue,
        -outline => '',
        -stipple => $stipple,
        -tags    => \@tags,
    );

    # ---- Poligono inferior: central → -1σ (rojo) ----
    $canvas->createPolygon(
        $x_left,  $y_center_l,
        $x_right, $y_center_r,
        $x_right, $y_lower_r,
        $x_left,  $y_lower_l,
        -fill    => $red,
        -outline => '',
        -stipple => $stipple,
        -tags    => \@tags,
    );

    # ---- Linea central de regresion (solida) ----
    $canvas->createLine(
        $x_left, $y_center_l, $x_right, $y_center_r,
        -fill  => $blue,
        -width => 2,
        -tags  => \@tags,
    );

    # ---- Limite superior +1σ (dashed) ----
    $canvas->createLine(
        $x_left, $y_upper_l, $x_right, $y_upper_r,
        -fill  => $blue,
        -width => 1,
        -dash  => [4, 3],
        -tags  => \@tags,
    );

    # ---- Limite inferior -1σ (dashed) ----
    $canvas->createLine(
        $x_left, $y_lower_l, $x_right, $y_lower_r,
        -fill  => $red,
        -width => 1,
        -dash  => [4, 3],
        -tags  => \@tags,
    );

    # ---- Manejadores circulares en los extremos ----
    my $hr = 5;   # radio del handler
    my $handler_fill = $is_preview ? '' : '#131722';
    for my $pt ( [$x_left, $y_center_l], [$x_right, $y_center_r] ) {
        $canvas->createOval(
            $pt->[0] - $hr, $pt->[1] - $hr,
            $pt->[0] + $hr, $pt->[1] + $hr,
            -outline => $blue,
            -fill    => $handler_fill,
            -width   => 2,
            -tags    => \@tags,
        );
    }
}

# --- VWAP handlers ---
sub _vwap_start {
    my ($self, $global_x, $global_y) = @_;
    my $ix = $self->_reg_channel_index_from_global($global_x, $global_y);
    return unless defined $ix;

    $self->{vwap_selecting} = 0;
    $self->{price_canvas}->configure(-cursor => 'arrow') if $self->{price_canvas};

    my $ind = $self->{indicators}->get('AnchoredVWAP');
    if ($ind) {
        $ind->add_manual_anchor($ix);
        $ind->compute_all($self->{market});
        $self->{_render_state} = undef;
        $self->request_render();
    }
}

# --- Volume Profile handlers ---
sub _vp_start {
    my ($self, $global_x, $global_y) = @_;
    my $ix = $self->_reg_channel_index_from_global($global_x, $global_y);
    return unless defined $ix;

    $self->{vp_preview} = { from_index => $ix, to_index => $ix };
}

sub _vp_drag_to {
    my ($self, $global_x, $global_y) = @_;
    return unless $self->{vp_preview};
    my $ix = $self->_reg_channel_index_from_global($global_x, $global_y);
    return unless defined $ix;

    $self->{vp_preview}{to_index} = $ix;
    
    # Draw preview box
    $self->{price_canvas}->delete('vp_preview') if $self->{price_canvas};
    my $pscale = $self->{price_scale};
    return unless $pscale;
    my $idx1 = $self->{vp_preview}{from_index};
    my $idx2 = $self->{vp_preview}{to_index};
    ($idx1, $idx2) = ($idx2, $idx1) if $idx1 > $idx2;
    my $x1 = $pscale->index_to_center_x($idx1);
    my $x2 = $pscale->index_to_center_x($idx2);
    $self->{price_canvas}->createRectangle($x1, 0, $x2, $pscale->{y_height} // 500,
        -fill => '#3b4452', -stipple => 'gray25', -outline => '#83a9ff', -tags => ['vp_preview']
    );
}

sub _vp_finish {
    my ($self) = @_;
    return unless $self->{vp_preview};
    my $start = $self->{vp_preview}{from_index};
    my $end   = $self->{vp_preview}{to_index};
    ($start, $end) = ($end, $start) if $start > $end;

    $self->{vp_selecting} = 0;
    $self->{vp_preview} = undef;
    $self->{price_canvas}->configure(-cursor => 'arrow') if $self->{price_canvas};
    $self->{price_canvas}->delete('vp_preview') if $self->{price_canvas};

    my $ind = $self->{indicators}->get('VolumeProfile');
    if ($ind) {
        $ind->add_manual_anchor($start, $end);
        $ind->compute_all($self->{market});
        $self->{_render_state} = undef;
        $self->request_render();
    }
}

# --- Public pan methods (called from market.pl) ---

sub drag_start {
    my ($self, $global_x, $global_y) = @_;
    $self->{_drag_started_in_chart} = 0;
    $self->{_drag_start_replay_index} = undef;
    $self->{_drag_moved} = 0;

    if ( $self->{reg_channel_selecting} ) {
        $self->_reg_channel_start( $global_x, $global_y )
            if $self->_point_in_widget( $self->{price_canvas}, $global_x, $global_y );
        return;
    }

    if ( $self->{vp_selecting} ) {
        $self->_vp_start( $global_x, $global_y )
            if $self->_point_in_widget( $self->{price_canvas}, $global_x, $global_y );
        return;
    }

    if ( $self->{vwap_selecting} ) {
        $self->_vwap_start( $global_x, $global_y )
            if $self->_point_in_widget( $self->{price_canvas}, $global_x, $global_y );
        return;
    }

    if ( $self->{manual_fib_selecting} ) {
        $self->_manual_fib_start( $global_x, $global_y )
            if $self->_point_in_widget( $self->{price_canvas}, $global_x, $global_y );
        return;
    }

    if ( $self->_point_in_widget( $self->{price_scale_canvas}, $global_x, $global_y ) ) {
        $self->_price_scale_drag_start($global_y) unless $self->{_price_scale_dragging};
        return;
    }
    return if $self->_point_in_widget( $self->{volume_scale_canvas}, $global_x, $global_y );
    return if $self->_point_in_widget( $self->{atr_scale_canvas},   $global_x, $global_y );
    return unless $self->_point_in_widget( $self->{price_canvas}, $global_x, $global_y )
               || $self->_point_in_widget( $self->{volume_canvas}, $global_x, $global_y )
               || $self->_point_in_widget( $self->{atr_canvas}, $global_x, $global_y );

    $self->{_drag_start_x}      = $global_x;
    $self->{_drag_start_y}      = $global_y;
    $self->{_drag_start_offset} = $self->{offset};
    $self->{_drag_started_in_chart} = 1;
    $self->{_drag_start_replay_index} = $self->_index_from_global_point($global_x, $global_y);
    # Capturar rango Y al inicio del drag para pan vertical relativo al punto de inicio
    $self->{_drag_start_y_min}  = $self->{y_min_manual};
    $self->{_drag_start_y_max}  = $self->{y_max_manual};
}

sub drag_end {
    my ($self, $global_x, $global_y) = @_;

    if ( $self->{reg_channel_selecting} && !$self->{reg_channel_preview} ) {
        return;
    }
    if ( $self->{reg_channel_preview} ) {
        $self->_reg_channel_finish();
        return;
    }

    if ( $self->{vp_selecting} && !$self->{vp_preview} ) {
        return;
    }
    if ( $self->{vp_preview} ) {
        $self->_vp_finish();
        return;
    }

    if ( $self->{manual_fib_selecting} && !$self->{manual_fib_preview} ) {
        return;
    }
    if ( $self->{manual_fib_preview} ) {
        $self->_manual_fib_finish();
        return;
    }

    my $was_click = defined $self->{_drag_start_x}
                 && $self->{_drag_started_in_chart}
                 && !$self->{_drag_moved};
    if ($was_click) {
        my $idx = $self->{_drag_start_replay_index};
        $idx = $self->_index_from_global_point($global_x, $global_y)
            if !defined $idx && defined $global_x && defined $global_y;
        $self->set_replay_start_index($idx) if defined $idx;
    }

    $self->{_drag_start_x} = undef;
    $self->{_drag_start_y} = undef;
    $self->{_drag_started_in_chart} = 0;
    $self->{_drag_start_replay_index} = undef;
    $self->{_drag_moved} = 0;
    $self->_price_scale_drag_end() if $self->{_price_scale_dragging};
}

sub drag_move {
    my ($self, $global_x, $global_y) = @_;

    if ( $self->{reg_channel_selecting} ) {
        $self->_reg_channel_drag_to( $global_x, $global_y )
            if $self->{reg_channel_preview};
        return;
    }

    if ( $self->{vp_selecting} ) {
        $self->_vp_drag_to( $global_x, $global_y )
            if $self->{vp_preview};
        return;
    }

    if ( $self->{vwap_selecting} ) {
        return; # Nothing to drag for VWAP
    }

    if ( $self->{manual_fib_selecting} ) {
        $self->_manual_fib_drag_to( $global_x, $global_y )
            if $self->{manual_fib_preview};
        return;
    }

    if ( $self->{_price_scale_dragging} ) {
        $self->_price_scale_drag_to($global_y);
        return;
    }
    return unless defined $self->{_drag_start_x};

    # --- Pan horizontal (siempre) ---
    my $dx    = $global_x - $self->{_drag_start_x};
    my $dy0   = $global_y - ( $self->{_drag_start_y} // $global_y );
    $self->{_drag_moved} = 1 if abs($dx) > 3 || abs($dy0) > 3;
    my $bar_w = ( $self->{price_canvas}->width() || 900 ) / ( $self->{visible_bars} || 100 );
    $bar_w    = 0.5 if $bar_w < 0.5;

    my $new_off = $self->{_drag_start_offset} + int( $dx / $bar_w );
    # Permitir padding de un ancho de ventana en cada extremo para espacio vacio
    my $pad     = $self->{visible_bars};
    my $max_off = $self->{market}->last_index() + $pad;
    my $min_off = -$pad;
    if ( $self->{replay_mode} && defined $self->{replay_cursor} ) {
        my $replay_min_off = $self->_offset_for_index_with_right_space( $self->{replay_cursor} );
        $min_off = $replay_min_off if $replay_min_off > $min_off;
    }
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
    $self->_anchor_cursor_to_right_edge()
        if $self->{replay_mode} && defined $self->{replay_cursor};
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
    my $min_off = -$self->_right_space_bars($new_bars);
    if ( $self->{replay_mode} && defined $self->{replay_cursor} ) {
        my $min_replay_off = $self->_offset_for_index_with_right_space( $self->{replay_cursor}, $new_bars );
        $min_off = $min_replay_off if $min_replay_off > $min_off;
    }
    if ( $new_off < $min_off ) { $new_off = $min_off; $clamped = 1; }
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

sub set_lq_indicator {
    my ($self, $ind) = @_;
    $self->{_lq_indicator} = $ind;
}

sub set_strategy_indicator {
    my ($self, $ind) = @_;
    $self->{_strategy_indicator} = $ind;
}

sub set_vp_indicator {
    my ($self, $ind) = @_;
    $self->{_vp_indicator} = $ind;
}

sub set_vwap_indicator {
    my ($self, $ind) = @_;
    $self->{_vwap_indicator} = $ind;
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

sub begin_replay_selection {
    my ($self) = @_;
    $self->_stop_replay_timer();
    $self->{replay_mode}    = 0;
    $self->{replay_selecting} = 1;
    $self->{replay_playing} = 0;
    $self->{replay_cursor}  = undef;
    $self->{selected_replay_index} = undef;
    $self->{_render_state}  = undef;
    $self->{on_replay_state_change}->('selecting') if $self->{on_replay_state_change};
    $self->request_render();
}

sub cancel_replay_selection {
    my ($self) = @_;
    return unless $self->{replay_selecting} && !$self->{replay_mode};
    $self->{replay_selecting} = 0;
    $self->{selected_replay_index} = undef;
    $self->{_render_state} = undef;
    $self->{on_replay_state_change}->('exited') if $self->{on_replay_state_change};
    $self->request_render();
}

sub start_replay {
    my ($self, $index) = @_;
    # Usar la vela indicada por argumento. Si no hay, conservar el
    # comportamiento anterior: ultima vela real visible actual.
    my ($v_start, $v_end, $d_start, $d_end) = $self->compute_window();
    my $start_index = defined $index ? $index : $self->{selected_replay_index};
    $start_index = $d_end unless defined $start_index;
    my $last = $self->{market}->last_index();
    return if $last < 0;
    $start_index = 0     if $start_index < 0;
    $start_index = $last if $start_index > $last;

    $self->_stop_replay_timer();
    $self->{replay_mode}    = 1;
    $self->{replay_selecting} = 0;
    $self->{replay_cursor}  = $start_index;
    $self->{selected_replay_index} = $start_index;
    $self->{replay_playing} = 0;
    $self->{replay_speed}   = 400;
    $self->{_render_state}  = undef;
    $self->_anchor_cursor_to_right_edge();
    $self->{on_replay_state_change}->('started') if $self->{on_replay_state_change};
    $self->request_render();
}

sub exit_replay {
    my ($self) = @_;
    $self->_stop_replay_timer();
    $self->{replay_mode}    = 0;
    $self->{replay_selecting} = 0;
    $self->{replay_playing} = 0;
    $self->{replay_cursor}  = undef;
    $self->{selected_replay_index} = undef;
    $self->{_render_state}  = undef;
    $self->{on_replay_state_change}->('exited') if $self->{on_replay_state_change};
    $self->goto_last();
}

# Avanza el cursor una barra hacia el futuro y actualiza el offset
# para que el cursor quede visible antes del espacio vacio derecho.
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

# Ajusta el offset para que replay_cursor conserve espacio vacio a la derecha.
# Si el cursor retrocede mas alla del borde izquierdo, ajusta en esa direccion.
sub _anchor_cursor_to_right_edge {
    my ($self) = @_;
    my $cursor    = $self->{replay_cursor};
    my $real_last = $self->{market}->last_index();
    return unless defined $cursor;
    $cursor = 0          if $cursor < 0;
    $cursor = $real_last if $cursor > $real_last;
    $self->{replay_cursor} = $cursor;

    my $new_off = $self->_offset_for_index_with_right_space($cursor);

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

sub _draw_replay_marker {
    my ($self, $canvas, $d_start, $d_end, $scale) = @_;
    return unless $canvas && $scale;
    $canvas->delete('replay_marker');

    my $idx = $self->{replay_mode}
        ? $self->{replay_cursor}
        : ( $self->{replay_selecting} ? $self->{selected_replay_index} : undef );
    return unless defined $idx;
    return if $idx < $d_start || $idx > $d_end;

    my $x = int( $scale->index_to_center_x($idx) + 0.5 );
    return if $x < 0 || $x > $scale->{x_width};

    my $h = $scale->{y_height} || ($canvas->height || 500);
    my $color = '#83a9ff';
    my $label = $self->{replay_mode} ? 'REPLAY' : 'RP START';

    $canvas->createLine( $x, 0, $x, $h,
        -fill  => $color,
        -width => 1.5,
        -dash  => [ 5, 4 ],
        -tags  => [ 'replay_marker' ],
    );
    $canvas->createText( $x + 4, 30,
        -text   => $label,
        -fill   => $color,
        -font   => [ 'Helvetica', 8, 'bold' ],
        -anchor => 'w',
        -tags   => [ 'replay_marker' ],
    );
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
    my $hi = $self->{replay_mode} && defined $self->{replay_cursor}
        ? $self->{replay_cursor}
        : $self->{market}->last_index();
    $ix    = $lo if $ix < $lo;
    $ix    = $hi if $ix > $hi;
    my $snapped_x = int( $scale->index_to_center_x($ix) + 0.5 );

    # La linea horizontal solo se dibuja cuando el mouse esta sobre el panel de precio
    my $price_y = ( $self->{_crosshair_source} eq 'price' ) ? $self->{crosshair_y} : undef;
    $self->{price_panel}->draw_crosshair( $snapped_x, $price_y );

    # Label de fecha/hora en el time-axis (paneles sincronizados)
    my $ts = $self->{market}->get_timestamp($ix);
    $self->{price_panel}->draw_crosshair_time_label(  $snapped_x, $ts );
    $self->{volume_panel}->draw_crosshair_time_label( $snapped_x, $ts );
    $self->{atr_panel}->draw_crosshair_time_label(    $snapped_x, $ts );

    # OHLC legend en la esquina superior izquierda del canvas de precio
    my $candle = $self->{market}->get_candle($ix);
    my $prev   = $ix > 0 ? $self->{market}->get_candle($ix - 1) : undef;
    $self->{price_panel}->draw_ohlc_legend($candle, $prev ? $prev->{close} : undef);

    # Valor de volumen en la barra bajo el cursor
    my $volume_y = ( $self->{_crosshair_source} eq 'volume' ) ? $self->{crosshair_y} : undef;
    my $volume_val = $candle ? $candle->{volume} : undef;
    $self->{volume_panel}->draw_crosshair( $snapped_x, $volume_val, $volume_y );

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
    my $was_replay = $self->{replay_mode} || $self->{replay_selecting};
    $self->_stop_replay_timer();
    $self->{replay_mode}    = 0;
    $self->{replay_selecting} = 0;
    $self->{replay_playing} = 0;
    $self->{replay_cursor}  = undef;
    $self->{selected_replay_index} = undef;
    $self->{on_replay_state_change}->('exited') if $was_replay && $self->{on_replay_state_change};
    $self->{market}->set_timeframe($tf);
    $self->{market}->build_volume_index($tf);   # Reconstruir indice de volumen multi-temporal
    $self->{indicators}->reset_all();
    $self->{indicators}->compute_all( $self->{market} );

    # Recomputar Liquidity y SMC al cambiar timeframe
    if ( $self->{_lq_indicator} ) {
        $self->{_lq_indicator}->reset();
        $self->{_lq_indicator}->compute_all( $self->{market} );
    }
    if ( $self->{_smc_indicator} ) {
        $self->{_smc_indicator}->reset();
        $self->{_smc_indicator}->compute_all( $self->{market} );
    }
    # Recomputar nuevos indicadores (Fase 2)
    if ( $self->{_strategy_indicator} ) {
        $self->{_strategy_indicator}->reset();
        $self->{_strategy_indicator}->compute_all( $self->{market} );
    }
    if ( $self->{_vp_indicator} ) {
        $self->{_vp_indicator}->reset();
        $self->{_vp_indicator}->compute_all( $self->{market} );
    }
    if ( $self->{_vwap_indicator} ) {
        $self->{_vwap_indicator}->reset();
        $self->{_vwap_indicator}->compute_all( $self->{market} );
    }

    $self->reset_view();
}

sub reset_view {
    my ($self) = @_;
    my $was_replay = $self->{replay_mode} || $self->{replay_selecting};
    $self->_stop_replay_timer();
    $self->{replay_mode}    = 0;
    $self->{replay_selecting} = 0;
    $self->{replay_playing} = 0;
    $self->{replay_cursor}  = undef;
    $self->{selected_replay_index} = undef;
    $self->{on_replay_state_change}->('exited') if $was_replay && $self->{on_replay_state_change};
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
