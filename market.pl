#!/usr/bin/perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin;       # siempre apunta al directorio del script sin importar desde donde se ejecute

use Tk;

# Use Time::Moment if available, otherwise fall back to pure-Perl parser
my $HAS_MOMENT;
BEGIN {
    eval { require Time::Moment; $HAS_MOMENT = 1 };
}

sub parse_ts {
    my ($ts) = @_;
    if ($HAS_MOMENT) {
        return Time::Moment->from_string($ts)->epoch;
    }
    return 0 unless $ts =~
        /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})([-+])(\d{2}):(\d{2})$/;
    my ($y,$mo,$d,$h,$mi,$s,$sign,$tzh,$tzm) = ($1,$2,$3,$4,$5,$6,$7,$8,$9);
    my @dim = (0,31,59,90,120,151,181,212,243,273,304,334);
    my $leap = ($y%4==0 && ($y%100!=0 || $y%400==0)) ? 1 : 0;
    my $doy  = $dim[$mo-1] + ($mo>2 ? $leap : 0) + $d;
    my $days = ($y-1970)*365 + int(($y-1969)/4)
               - int(($y-1901)/100) + int(($y-1601)/400) + $doy - 1;
    my $utc  = $days*86400 + $h*3600 + $mi*60 + $s;
    return $utc - ($tzh*3600 + $tzm*60) * ($sign eq '+' ? 1 : -1);
}

use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::Indicators::SMC_Structures;
use Market::Indicators::Liquidity;
use Market::Overlays::SMC_Structures;
use Market::Overlays::Liquidity;
use Market::ChartEngine;

# ---- Configuration ----
my $CSV_FILE     = '2026_03.csv';
my $ATR_PERIOD   = 14;
my $PRICE_H      = 500;
my $ATR_H        = 150;
my $SCALE_W      = 75;
my $INITIAL_BARS = 100;
my $BG           = '#131722';
my $SCALE_BG     = '#1e222d';

# ---- 1. Load CSV data ----
print "Loading $CSV_FILE...\n";
my $market = Market::MarketData->new();

open my $fh, '<', $CSV_FILE or die "Cannot open $CSV_FILE: $!";
<$fh>;    # skip header
while ( my $line = <$fh> ) {
    chomp $line;
    my ($time_str, $open, $high, $low, $close, $volume) = split /,/, $line;
    next unless defined $volume;

    my $epoch = parse_ts($time_str);
    $market->add_candle({
        time   => $epoch,
        open   => $open   + 0,
        high   => $high   + 0,
        low    => $low    + 0,
        close  => $close  + 0,
        volume => $volume + 0,
    });
}
close $fh;

# ---- 2. Build higher timeframes (5m, 15m, 1h, 2h, 4h, D, W) ----
$market->build_timeframes();
my $d = $market->get_data();
printf "Loaded: 1m=%d  5m=%d  15m=%d  1h=%d  2h=%d  4h=%d  D=%d  W=%d candles\n",
    scalar @{ $d->{'1'}     // [] },
    scalar @{ $d->{'5'}     // [] },
    scalar @{ $d->{'15'}    // [] },
    scalar @{ $d->{'60'}    // [] },
    scalar @{ $d->{'120'}   // [] },
    scalar @{ $d->{'240'}   // [] },
    scalar @{ $d->{'1440'}  // [] },
    scalar @{ $d->{'10080'} // [] };

# ---- 3. Compute indicators for 1m timeframe ----
my $indicators = Market::IndicatorManager->new();
$indicators->register( 'ATR', Market::Indicators::ATR->new($ATR_PERIOD) );

print "Computing ATR($ATR_PERIOD) with MXNet tensors...\n";
$indicators->compute_all($market);
print "Done.\n";

# ---- 3b. Computar indicador SMC (Swing Points, BOS, FVG) ----
# ---- 3b. Maquina de estados de Liquidez (SWEEP / GRAB / RUN) ----
print "Computing Liquidity state machine (SWEEP/GRAB/RUN)...\n";
my $lq_ind = Market::Indicators::Liquidity->new( depth => 3, atr_period => $ATR_PERIOD );
$lq_ind->compute_all($market);
my $lq_res = $lq_ind->get_resolved();
printf "  Niveles detectados: %d  Resueltos: %d  (SWEEP=%d GRAB=%d RUN=%d)\n",
    scalar @{ $lq_ind->get_levels() },
    scalar @$lq_res,
    scalar( grep { ($_->{classification}//'') eq 'SWEEP' } @$lq_res ),
    scalar( grep { ($_->{classification}//'') eq 'GRAB'  } @$lq_res ),
    scalar( grep { ($_->{classification}//'') eq 'RUN'   } @$lq_res );
print "Done.\n";

# ---- 3c. SMC Structures vinculado con Liquidity ----
print "Computing SMC Structures (BOS, CHoCH, FVG)...\n";
my $smc_ind = Market::Indicators::SMC_Structures->new( depth => 3 );
$smc_ind->set_liquidity_indicator($lq_ind);   # vincula para boosted CHoCH
$smc_ind->compute_all($market);
printf "  SH: %d  SL: %d  BOS: %d  CHoCH: %d  FVG: %d\n",
    scalar @{ $smc_ind->get_swing_highs()  },
    scalar @{ $smc_ind->get_swing_lows()   },
    scalar @{ $smc_ind->get_bos_events()   },
    scalar @{ $smc_ind->get_choch_events() },
    scalar @{ $smc_ind->get_fvg_zones()    };
print "Done.\n";

# ---- 4. Build Tk window ----
my $mw = MainWindow->new();
$mw->title("Market Chart  |  1m");
$mw->configure( -bg => $BG );
$mw->resizable( 1, 1 );
$mw->geometry("1200x800");   # ventana normal redimensionable; F11 activa pantalla completa

# Declarar antes de usarse en los subs/bindings de teclado
my $fs_btn;
my $engine;
sub _toggle_fullscreen {
    my $is_fs = $mw->attributes('-fullscreen');
    $mw->attributes( -fullscreen => !$is_fs );
    if ( !$is_fs ) {
        $fs_btn->configure( -text => '[ # ]', -fg => '#f6c90e' );
    } else {
        $fs_btn->configure( -text => '[  ]',  -fg => '#b2b5be' );
    }
    # Esperar 50ms a que el gestor de ventanas termine el resize,
    # luego anclar la ultima vela al borde derecho.
    # Sin esto el canvas crece pero el offset queda donde estaba,
    # dejando espacio vacio a la derecha.
    $mw->after( 50, sub { $engine->goto_last() if defined $engine } );
}

# F11 y Escape sincronizan el mismo boton del toolbar
$mw->bind( '<Escape>', sub {
    $mw->attributes( -fullscreen => 0 );
    $fs_btn->configure( -text => '[  ]', -fg => '#b2b5be' ) if defined $fs_btn;
    $mw->after( 50, sub { $engine->goto_last() if defined $engine } );
});
$mw->bind( '<F11>', sub { _toggle_fullscreen() } );

# Cerrar ventana o Ctrl+Q mata el proceso
$mw->protocol( 'WM_DELETE_WINDOW', sub { exit 0 } );
$mw->bind( '<Control-q>', sub { exit 0 } );
$mw->bind( '<Control-Q>', sub { exit 0 } );

# Toolbar (timeframe buttons + reset)
my $toolbar = $mw->Frame( -bg => '#1e222d' )
    ->pack( -fill => 'x', -side => 'top' );

# Price chart row
my $price_row = $mw->Frame( -bg => $BG )
    ->pack( -fill => 'both', -expand => 1 );

my $price_canvas = $price_row->Canvas(
    -bg                 => $BG,
    -height             => $PRICE_H,
    -highlightthickness => 0,
)->pack( -side => 'left', -fill => 'both', -expand => 1 );

my $price_scale_canvas = $price_row->Canvas(
    -bg                 => $SCALE_BG,
    -width              => $SCALE_W,
    -highlightthickness => 0,
)->pack( -side => 'right', -fill => 'y' );

# ATR chart row
my $atr_row = $mw->Frame( -bg => $BG )
    ->pack( -fill => 'x' );

my $atr_canvas = $atr_row->Canvas(
    -bg                 => $BG,
    -height             => $ATR_H,
    -highlightthickness => 0,
)->pack( -side => 'left', -fill => 'both', -expand => 1 );

my $atr_scale_canvas = $atr_row->Canvas(
    -bg                 => $SCALE_BG,
    -width              => $SCALE_W,
    -height             => $ATR_H,
    -highlightthickness => 0,
)->pack( -side => 'right', -fill => 'y' );

# ---- 5. Chart engine ----
$engine = Market::ChartEngine->new(
    market             => $market,
    indicators         => $indicators,
    price_canvas       => $price_canvas,
    price_scale_canvas => $price_scale_canvas,
    atr_canvas         => $atr_canvas,
    atr_scale_canvas   => $atr_scale_canvas,
    visible_bars       => $INITIAL_BARS,
);

# ---- Timeframe buttons (1m → W) ----
my @TIMEFRAMES = (
    { tf => '1',     label => '1m'  },
    { tf => '5',     label => '5m'  },
    { tf => '15',    label => '15m' },
    { tf => '60',    label => '1h'  },
    { tf => '120',   label => '2h'  },
    { tf => '240',   label => '4h'  },
    { tf => '1440',  label => 'D'   },
    { tf => '10080', label => 'W'   },
);
for my $entry ( @TIMEFRAMES ) {
    my $tf  = $entry->{tf};
    my $lbl = $entry->{label};
    $toolbar->Button(
        -text             => $lbl,
        -bg               => '#2a2d3e',
        -fg               => '#b2b5be',
        -relief           => 'flat',
        -padx             => 8,
        -pady             => 3,
        -activebackground => '#3a3d4e',
        -activeforeground => '#ffffff',
        -command          => sub {
            $mw->title("Market Chart  |  $lbl");
            $engine->set_timeframe($tf);
        },
    )->pack( -side => 'left', -padx => 1, -pady => 2 );
}

$toolbar->Button(
    -text             => 'Reset',
    -bg               => '#2a2d3e',
    -fg               => '#f6c90e',
    -relief           => 'flat',
    -padx             => 10,
    -pady             => 3,
    -activebackground => '#3a3d4e',
    -command          => sub { $engine->reset_view(); },
)->pack( -side => 'left', -padx => 8, -pady => 2 );

# Boton modo escala Y: Auto (verde) / Manual (amarillo)
# Cambia cuando el usuario arrastra el eje Y o hace click aqui
my $mode_btn;
sub _update_mode_btn {
    my ($is_auto) = @_;
    return unless defined $mode_btn;
    if ($is_auto) {
        $mode_btn->configure( -text => 'Escala: Auto',   -fg => '#26a69a' );
    } else {
        $mode_btn->configure( -text => 'Escala: Manual', -fg => '#f6c90e' );
    }
}
$mode_btn = $toolbar->Button(
    -text             => 'Escala: Auto',
    -bg               => '#2a2d3e',
    -fg               => '#26a69a',
    -relief           => 'flat',
    -padx             => 10,
    -pady             => 3,
    -activebackground => '#3a3d4e',
    -activeforeground => '#ffffff',
    -command          => sub { $engine->toggle_auto_scale() },
)->pack( -side => 'left', -padx => 2, -pady => 2 );

# ---- Separador visual ----
$toolbar->Label( -text => '|', -bg => '#1e222d', -fg => '#3a3d4e' )
    ->pack( -side => 'left', -padx => 4 );

# ---- Controles de Replay (Seccion 3) ----
# Boton para entrar/salir de modo Replay
my $replay_btn;
my $play_btn;

sub _update_replay_ui {
    my ($state) = @_;
    return unless defined $replay_btn;
    if ( $state eq 'exited' ) {
        $replay_btn->configure( -text => 'Replay', -fg => '#b2b5be' );
        $play_btn->configure(   -text => '>',       -fg => '#b2b5be' ) if defined $play_btn;
    } elsif ( $state eq 'started' ) {
        $replay_btn->configure( -text => 'EXIT RP', -fg => '#f6c90e' );
        $play_btn->configure(   -text => '>',        -fg => '#26a69a' ) if defined $play_btn;
    } elsif ( $state eq 'playing' ) {
        $play_btn->configure( -text => '| |', -fg => '#f6c90e' ) if defined $play_btn;
    } elsif ( $state eq 'paused' || $state eq 'end' ) {
        $play_btn->configure( -text => '>',   -fg => '#26a69a' ) if defined $play_btn;
    }
}

$replay_btn = $toolbar->Button(
    -text             => 'Replay',
    -bg               => '#2a2d3e',
    -fg               => '#b2b5be',
    -relief           => 'flat',
    -padx             => 8,
    -pady             => 3,
    -activebackground => '#3a3d4e',
    -command          => sub {
        if ( $engine->{replay_mode} ) {
            $engine->exit_replay();
        } else {
            $engine->start_replay();
        }
    },
)->pack( -side => 'left', -padx => 1, -pady => 2 );

# Retroceder una barra
$toolbar->Button(
    -text             => '|<',
    -bg               => '#2a2d3e',
    -fg               => '#b2b5be',
    -relief           => 'flat',
    -padx             => 6,
    -pady             => 3,
    -activebackground => '#3a3d4e',
    -command          => sub { $engine->step_backward() },
)->pack( -side => 'left', -padx => 1, -pady => 2 );

# Play / Pause (toggle)
$play_btn = $toolbar->Button(
    -text             => '>',
    -bg               => '#2a2d3e',
    -fg               => '#26a69a',
    -relief           => 'flat',
    -padx             => 8,
    -pady             => 3,
    -activebackground => '#3a3d4e',
    -command          => sub { $engine->toggle_play_replay() },
)->pack( -side => 'left', -padx => 1, -pady => 2 );

# Avanzar una barra
$toolbar->Button(
    -text             => '>|',
    -bg               => '#2a2d3e',
    -fg               => '#b2b5be',
    -relief           => 'flat',
    -padx             => 6,
    -pady             => 3,
    -activebackground => '#3a3d4e',
    -command          => sub { $engine->step_forward() },
)->pack( -side => 'left', -padx => 1, -pady => 2 );

# Fast Forward
$toolbar->Button(
    -text             => '>>',
    -bg               => '#2a2d3e',
    -fg               => '#b2b5be',
    -relief           => 'flat',
    -padx             => 6,
    -pady             => 3,
    -activebackground => '#3a3d4e',
    -command          => sub { $engine->fast_forward_replay() },
)->pack( -side => 'left', -padx => 1, -pady => 2 );

# Boton cerrar (siempre visible en pantalla completa)
$toolbar->Button(
    -text             => '  X  ',
    -bg               => '#2a2d3e',
    -fg               => '#ef5350',
    -relief           => 'flat',
    -padx             => 10,
    -pady             => 3,
    -activebackground => '#ef5350',
    -activeforeground => '#ffffff',
    -font             => ['Helvetica', 10, 'bold'],
    -command          => sub { exit 0 },
)->pack( -side => 'right', -padx => 4, -pady => 2 );

# Boton pantalla completa — muestra el estado actual y lo alterna al hacer click.
# El texto cambia entre "[  ]" (ventana normal) y "[ # ]" (pantalla completa).
# Los canvas se adaptan solos porque <Configure> llama a request_render() al
# cambiar el tamanio de la ventana.
$fs_btn = $toolbar->Button(
    -text             => '[  ]',
    -bg               => '#2a2d3e',
    -fg               => '#b2b5be',
    -relief           => 'flat',
    -padx             => 10,
    -pady             => 3,
    -activebackground => '#3a3d4e',
    -activeforeground => '#ffffff',
    -font             => ['Helvetica', 10],
    -command          => \&_toggle_fullscreen,
)->pack( -side => 'right', -padx => 2, -pady => 2 );

# ---- 6. Bind events and first render ----
# Registrar overlays SMC y Liquidez
$engine->set_lq_indicator($lq_ind);
$engine->set_smc_indicator($smc_ind);
$engine->add_overlay( Market::Overlays::SMC_Structures->new( indicator => $smc_ind ) );
$engine->add_overlay( Market::Overlays::Liquidity->new(      indicator => $lq_ind  ) );

$engine->set_scale_mode_callback( \&_update_mode_btn );
$engine->set_replay_callback( \&_update_replay_ui );
$engine->bind_events();

# Pan horizontal + vertical (Ev('X','Y') = coords globales de pantalla)
# El pan vertical solo actua en modo manual (ChartEngine lo verifica internamente)
$mw->bind( '<ButtonPress-1>',   [ sub { $engine->drag_start( $_[1], $_[2] ) }, Ev('X'), Ev('Y') ] );
$mw->bind( '<ButtonRelease-1>', sub { $engine->drag_end() } );
$mw->bind( '<B1-Motion>',       [ sub { $engine->drag_move( $_[1], $_[2] ) }, Ev('X'), Ev('Y') ] );

# Zoom: rueda del mouse
$mw->bind( '<Button-4>',   sub { $engine->zoom(-1) } );
$mw->bind( '<Button-5>',   sub { $engine->zoom( 1) } );
$mw->bind( '<MouseWheel>', [ sub { $engine->zoom( $_[1] > 0 ? -1 : 1 ) }, Ev('D') ] );

# Teclado: + zoom in,  - zoom out,  0 reset vista
$mw->bind( '<plus>',    sub { $engine->zoom(-1) } );
$mw->bind( '<equal>',   sub { $engine->zoom(-1) } );   # = sin shift
$mw->bind( '<minus>',   sub { $engine->zoom( 1) } );
$mw->bind( '<KP_Add>',  sub { $engine->zoom(-1) } );   # teclado numerico
$mw->bind( '<KP_Subtract>', sub { $engine->zoom( 1) } );
$mw->bind( '<0>',       sub { $engine->reset_view() } );
$mw->bind( '<End>',     sub { $engine->goto_last() } );   # ancla ultima vela al borde derecho

$mw->update();    # ensure canvas dimensions are resolved
$engine->render();

# Re-render on window resize
$price_canvas->bind( '<Configure>', sub { $engine->request_render(); } );
$atr_canvas->bind(   '<Configure>', sub { $engine->request_render(); } );

MainLoop();
