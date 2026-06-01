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

# ---- 2. Build higher timeframes (5m, 15m) ----
$market->build_timeframes();
printf "Loaded: 1m=%d  5m=%d  15m=%d candles\n",
    scalar @{ $market->get_data()->{'1'}  },
    scalar @{ $market->get_data()->{'5'}  },
    scalar @{ $market->get_data()->{'15'} };

# ---- 3. Compute indicators for 1m timeframe ----
my $indicators = Market::IndicatorManager->new();
$indicators->register( 'ATR', Market::Indicators::ATR->new($ATR_PERIOD) );

print "Computing ATR($ATR_PERIOD) with MXNet tensors...\n";
$indicators->compute_all($market);
print "Done.\n";

# ---- 4. Build Tk window ----
my $mw = MainWindow->new();
$mw->title("Market Chart  |  1m");
$mw->configure( -bg => $BG );
$mw->resizable( 1, 1 );
$mw->attributes( -fullscreen => 1 );

# Escape para salir de pantalla completa
$mw->bind( '<Escape>', sub { $mw->attributes( -fullscreen => 0 ) } );
$mw->bind( '<F11>',    sub {
    my $fs = $mw->attributes('-fullscreen');
    $mw->attributes( -fullscreen => !$fs );
});

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
my $engine = Market::ChartEngine->new(
    market             => $market,
    indicators         => $indicators,
    price_canvas       => $price_canvas,
    price_scale_canvas => $price_scale_canvas,
    atr_canvas         => $atr_canvas,
    atr_scale_canvas   => $atr_scale_canvas,
    visible_bars       => $INITIAL_BARS,
);

# ---- Timeframe buttons ----
for my $tf ( '1', '5', '15' ) {
    my $btn;
    $btn = $toolbar->Button(
        -text             => "${tf}m",
        -bg               => '#2a2d3e',
        -fg               => '#b2b5be',
        -relief           => 'flat',
        -padx             => 10,
        -pady             => 3,
        -activebackground => '#3a3d4e',
        -activeforeground => '#ffffff',
        -command          => sub {
            $mw->title("Market Chart  |  ${tf}m");
            $engine->set_timeframe($tf);
        },
    )->pack( -side => 'left', -padx => 2, -pady => 2 );
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

# ---- 6. Bind events and first render ----
$engine->bind_events();

# Pan: click izquierdo + arrastrar
# Ev('X') captura la coordenada global X en el momento del evento (forma correcta en Perl/Tk)
$mw->bind( '<ButtonPress-1>',   [ sub { $engine->drag_start( $_[1] ) }, Ev('X') ] );
$mw->bind( '<ButtonRelease-1>', sub { $engine->drag_end() } );
$mw->bind( '<B1-Motion>',       [ sub { $engine->drag_move( $_[1] ) }, Ev('X') ] );

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

$mw->update();    # ensure canvas dimensions are resolved
$engine->render();

# Re-render on window resize
$price_canvas->bind( '<Configure>', sub { $engine->request_render(); } );
$atr_canvas->bind(   '<Configure>', sub { $engine->request_render(); } );

MainLoop();
