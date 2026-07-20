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
use Market::Indicators::MarketRegime;
use Market::Indicators::ZigZagDirection;
use Market::Indicators::Strategy_Builder;
use Market::Indicators::VolumeProfile;
use Market::Indicators::AnchoredVWAP;
use Market::Indicators::PivotMissedReversal;
use Market::Indicators::InternalZigZag;
use Market::Indicators::ZonaInterna;
use Market::Overlays::SMC_Structures;
use Market::Overlays::Liquidity;
use Market::Overlays::ZigZagDirection;
use Market::Overlays::Strategy_Builder;
use Market::Overlays::VolumeProfile;
use Market::Overlays::AnchoredVWAP;
use Market::ChartEngine;

# ---- Configuration ----
my $CSV_FILE     = '2026_03.csv';
my $ATR_PERIOD   = 14;
my $PRICE_H      = 500;
my $VOLUME_H     = 90;
my $ATR_H        = 150;
my $SCALE_W      = 75;
my $INITIAL_BARS = 100;
my $BG           = '#131722';
my $SCALE_BG     = '#1e222d';
my $ZZ_EXTERNAL_LENGTH     = 150;
my $ZZ_INTERNAL_RESOLUTION = 15;
my $ZZ_INTERNAL_PERIOD     = 2;

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
$market->build_volume_index();   # Indice de volumen multi-temporal (Seccion 4.4)
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
my $zz_ind = Market::Indicators::ZigZagDirection->new(
    external_length     => $ZZ_EXTERNAL_LENGTH,
    internal_resolution => $ZZ_INTERNAL_RESOLUTION,
    internal_period     => $ZZ_INTERNAL_PERIOD,
);
$indicators->register( 'ZigZagDirection', $zz_ind );

print "Computing ATR($ATR_PERIOD) and ZigZag direction layers...\n";
$indicators->compute_all($market);
printf "  ZigZag externo: %d pivotes / %d segmentos  |  interno: %d pivotes / %d segmentos\n",
    scalar @{ $zz_ind->get_external_pivots() },
    scalar @{ $zz_ind->get_external_segments() },
    scalar @{ $zz_ind->get_internal_pivots() },
    scalar @{ $zz_ind->get_internal_segments() };
print "Done.\n";

# ---- 3a. ZigZag interno confirmado y ZonaInterna Fibonacci ----
# Estos cálculos son independientes de cualquier overlay: consumen ATR y
# pivotes confirmados, por lo que pueden emplearse también en Replay/backtest.
print "Computing confirmed Internal ZigZag and ZonaInterna...\n";
my $internal_zz_ind = Market::Indicators::InternalZigZag->new(
    pivot_length => 5, min_leg_bars => 4, atr_multiplier => 1.0,
    atr_indicator => $indicators->get('ATR'),
);
$internal_zz_ind->compute_all($market);
my $zona_interna_ind = Market::Indicators::ZonaInterna->new(
    zigzag_indicator => $internal_zz_ind,
    mintick => 0.01,
);
$zona_interna_ind->compute_all($market);
printf "  Internal ZigZag: %d pivotes / %d segmentos  |  ZonaInterna: %d niveles\n",
    scalar @{ $internal_zz_ind->get_pivots() },
    scalar @{ $internal_zz_ind->get_segments() },
    scalar @{ $zona_interna_ind->get_levels() };
print "Done.\n";

# ---- 3b. Computar indicador SMC (Swing Points, BOS, FVG) ----
# ---- 3b. Maquina de estados de Liquidez (SWEEP / GRAB / RUN) ----
print "Computing Liquidity state machine (SWEEP/GRAB/RUN)...\n";
my $lq_ind = Market::Indicators::Liquidity->new(
    depth          => 3,
    external_depth => $ZZ_EXTERNAL_LENGTH,
    atr_period     => $ATR_PERIOD,
);
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
my $smc_ind = Market::Indicators::SMC_Structures->new( depth => 5, external_depth => 25 );
$smc_ind->set_liquidity_indicator($lq_ind);   # vincula para boosted CHoCH
$smc_ind->compute_all($market);
printf "  SH: %d  SL: %d  BOS: %d  CHoCH: %d  FVG: %d\n",
    scalar @{ $smc_ind->get_swing_highs()  },
    scalar @{ $smc_ind->get_swing_lows()   },
    scalar @{ $smc_ind->get_bos_events()   },
    scalar @{ $smc_ind->get_choch_events() },
    scalar @{ $smc_ind->get_fvg_zones()    };
print "Done.\n";

# ---- 3d. Contexto de regimen (Liquidity + SMC + ATR) ----
print "Computing Market Regime...\n";
my $regime_ind = Market::Indicators::MarketRegime->new(
    liquidity_indicator => $lq_ind,
    smc_indicator       => $smc_ind,
);
$regime_ind->compute_all($market);
my $last_regime = $regime_ind->get_states()->[-1] // {};
printf "  Regimen actual: %s (confianza %.2f)\n",
    $last_regime->{state} // 'UNKNOWN',
    $last_regime->{confidence_score} // 0;
print "Done.\n";

# ---- 3e. Strategy Builder (SuperTrend, HalfTrend, RangeFilter, Supply/Demand) ----
print "Computing Strategy Builder...\n";
my $strategy_ind = Market::Indicators::Strategy_Builder->new(
    st_multiplier => 3.0,
    st_period     => 10,
    ht_amplitude  => 2,
    rf_period     => 100,
    rf_multiplier => 3.0,
);
$strategy_ind->set_smc_indicator($smc_ind);
$strategy_ind->compute_all($market);
printf "  SuperTrend: %d  HalfTrend: %d  RangeFilter: %d  Supply: %d  Demand: %d\n",
    scalar @{ $strategy_ind->get_supertrend()   },
    scalar @{ $strategy_ind->get_halftrend()    },
    scalar @{ $strategy_ind->get_range_filter() },
    scalar @{ $strategy_ind->get_supply_zones() },
    scalar @{ $strategy_ind->get_demand_zones() };
print "Done.\n";

# ---- 3f. Volume Profile (POC, VAH, VAL) ----
print "Computing Volume Profile...\n";
my $vp_ind = Market::Indicators::VolumeProfile->new(
    mode     => 'manual',
    num_bins => 50,
);
$vp_ind->set_smc_indicator($smc_ind);
$vp_ind->compute_all($market);
printf "  Perfiles generados: %d\n", scalar @{ $vp_ind->get_profiles() };
print "Done.\n";

# ---- 3g. Anchored VWAP Multipivot (5 anchors) ----
print "Computing Pivot Missed Reversal...\n";
my $pivot_missed_ind = Market::Indicators::PivotMissedReversal->new(length => 20);
$pivot_missed_ind->compute_all($market);
printf "  Regular: %d  Missed: %d\n",
    scalar @{ $pivot_missed_ind->get_regular_pivots() },
    scalar @{ $pivot_missed_ind->get_missed_pivots() };
print "Done.\n";

# ---- 3h. Anchored VWAP Multipivot + último missed pivot confirmado ----
print "Computing Anchored VWAP...\n";
my $vwap_ind = Market::Indicators::AnchoredVWAP->new(
    # Multiplicadores editables con
    # $engine->set_vwap_band_configuration(N, enabled => ..., multiplier => ...)
    std_mult_1     => 1.0,
    std_mult_2     => 2.0,
    band_1_enabled => 1,
    band_2_enabled => 1,
);
$vwap_ind->set_smc_indicator($smc_ind);
$vwap_ind->set_vp_indicator($vp_ind);
$vwap_ind->set_pivot_missed_indicator($pivot_missed_ind);
$vwap_ind->compute_all($market);
printf "  Lineas VWAP: %d\n", scalar @{ $vwap_ind->get_vwap_lines() };
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
    # luego mantener la ultima vela con el margen derecho obligatorio.
    # Sin esto el canvas crece pero el offset queda donde estaba.
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

# Volume chart row
my $volume_row = $mw->Frame( -bg => $BG )
    ->pack( -fill => 'x' );

my $volume_canvas = $volume_row->Canvas(
    -bg                 => $BG,
    -height             => $VOLUME_H,
    -highlightthickness => 0,
)->pack( -side => 'left', -fill => 'both', -expand => 1 );

my $volume_scale_canvas = $volume_row->Canvas(
    -bg                 => $SCALE_BG,
    -width              => $SCALE_W,
    -height             => $VOLUME_H,
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
    volume_canvas      => $volume_canvas,
    volume_scale_canvas => $volume_scale_canvas,
    atr_canvas         => $atr_canvas,
    atr_scale_canvas   => $atr_scale_canvas,
    visible_bars       => $INITIAL_BARS,
);

# ---- Timeframe buttons (1m → W) ----
my %overlay_visibility = (
    smc_enabled        => 1,
    show_hh            => 0,
    show_hl            => 0,
    show_lh            => 0,
    show_ll            => 0,
    show_sh            => 0,
    show_sl            => 0,
    show_choch         => 1,
    show_bos           => 1,
    show_internal_structure => 1,
    show_external_structure => 1,
    show_ob            => 1,
    show_trendlines    => 0,
    show_fvg           => 1,
    show_market_regime => 0,
    show_major_levels  => 1,
    show_premium_discount => 1,
    show_fibonacci_auto => 0,
    show_manual_fibonacci => 1,

    liquidity_enabled  => 1,
    show_bsl           => 1,
    show_ssl           => 1,
    show_eqh           => 1,
    show_eql           => 1,
    show_grab          => 1,
    show_sweep         => 1,
    show_run           => 1,

    show_zz_external   => 1,
    show_zz_internal   => 0,
    show_zz_hldv       => 0,

    # Strategy Builder
    strategy_enabled   => 1,
    show_supertrend    => 1,
    show_halftrend     => 1,
    show_range_filter  => 1,
    show_supply_demand => 1,

    # Volume Profile
    vp_enabled         => 1,
    show_vp_poc        => 1,
    show_vp_vah        => 1,
    show_vp_val        => 1,

    # Anchored VWAP
    vwap_enabled       => 1,
    show_vwap_band1    => 1,
    show_vwap_band2    => 1,
    show_vwap_band3    => 0,
);

my $refresh_overlays = sub {
    return unless defined $engine;
    $engine->{_render_state} = undef;
    $engine->request_render();
};

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

my $MENU_PANEL_BG  = '#2f3642';
my $MENU_DETAIL_BG = '#303743';
my $MENU_HOVER_BG  = '#3b4452';
my $MENU_BORDER    = '#485366';
my $MENU_FG        = '#f2f4f8';
my $MENU_MUTED_FG  = '#8b929e';
my $MENU_CHECK_FG  = '#83a9ff';
my $CHECK_MARK     = "\x{2713}";
my $OVERLAY_MENU_W = 560;
my $OVERLAY_MENU_H = 490;
my $OVERLAY_COL_W  = int( $OVERLAY_MENU_W / 2 );

my %overlay_parent_for = (
    show_hh            => 'smc_enabled',
    show_hl            => 'smc_enabled',
    show_lh            => 'smc_enabled',
    show_ll            => 'smc_enabled',
    show_sh            => 'smc_enabled',
    show_sl            => 'smc_enabled',
    show_choch         => 'smc_enabled',
    show_bos           => 'smc_enabled',
    show_internal_structure => 'smc_enabled',
    show_external_structure => 'smc_enabled',
    show_ob            => 'smc_enabled',
    show_trendlines    => 'smc_enabled',
    show_fvg           => 'smc_enabled',
    show_market_regime => 'smc_enabled',
    show_major_levels  => 'smc_enabled',
    show_premium_discount => 'smc_enabled',
    show_fibonacci_auto => 'smc_enabled',
    show_bsl           => 'liquidity_enabled',
    show_ssl           => 'liquidity_enabled',
    show_eqh           => 'liquidity_enabled',
    show_eql           => 'liquidity_enabled',
    show_grab          => 'liquidity_enabled',
    show_sweep         => 'liquidity_enabled',
    show_run           => 'liquidity_enabled',
);

my $overlay_button_text = "\x{25C8} INDICADORES Y OVERLAYS  \x{25BE}";
my $overlay_btn;
my $overlay_menu_panel;
my $overlay_main_panel;
my $overlay_detail_panel;
my $overlay_menu_visible = 0;
my $overlay_active_group = 'smc';
my @overlay_category_rows;
my @overlay_toggle_rows;
my (
    $is_overlay_key_enabled,
    $paint_overlay_categories,
    $update_overlay_menu_state,
    $add_overlay_separator,
    $add_overlay_toggle,
    $add_overlay_action,
    $build_overlay_detail,
    $show_overlay_group,
    $hide_overlay_menu,
    $show_overlay_menu,
    $toggle_overlay_menu,
);

$is_overlay_key_enabled = sub {
    my ($key) = @_;
    my $parent = $overlay_parent_for{$key};
    return 1 unless defined $parent;
    return $overlay_visibility{$parent} ? 1 : 0;
};

$paint_overlay_categories = sub {
    for my $item (@overlay_category_rows) {
        my $active = $item->{group} eq $overlay_active_group;
        my $bg     = $active ? $MENU_HOVER_BG : $MENU_PANEL_BG;
        for my $w (@{ $item->{widgets} }) {
            $w->configure( -bg => $bg );
        }
    }
};

$update_overlay_menu_state = sub {
    for my $item (@overlay_toggle_rows) {
        my $enabled = $is_overlay_key_enabled->( $item->{key} );
        my $checked = $overlay_visibility{ $item->{key} } ? 1 : 0;
        my $fg      = $enabled ? $MENU_FG : $MENU_MUTED_FG;
        my $checkfg = $checked
            ? ( $enabled ? $MENU_CHECK_FG : '#52617a' )
            : $MENU_MUTED_FG;

        $item->{check}->configure(
            -text => $checked ? $CHECK_MARK : ' ',
            -fg   => $checkfg,
            -bg   => $MENU_DETAIL_BG,
        );
        $item->{label}->configure(
            -fg => $fg,
            -bg => $MENU_DETAIL_BG,
        );
        $item->{row}->configure( -bg => $MENU_DETAIL_BG );
    }
};

$add_overlay_separator = sub {
    $overlay_detail_panel->Frame(
        -bg     => '#4a5360',
        -height => 1,
    )->pack( -fill => 'x', -padx => 10, -pady => 7 );
};

$add_overlay_toggle = sub {
    my ($label, $key, $is_main) = @_;
    my $row = $overlay_detail_panel->Frame(
        -bg     => $MENU_DETAIL_BG,
        -height => 34,
    )->pack( -fill => 'x' );
    $row->packPropagate(0);

    my $check = $row->Label(
        -text   => ' ',
        -width  => 3,
        -bg     => $MENU_DETAIL_BG,
        -fg     => $MENU_CHECK_FG,
        -font   => [ 'Helvetica', 12, 'bold' ],
        -anchor => 'center',
    )->pack( -side => 'left', -fill => 'y' );

    my $txt = $row->Label(
        -text   => $label,
        -bg     => $MENU_DETAIL_BG,
        -fg     => $MENU_FG,
        -font   => $is_main ? [ 'Helvetica', 10, 'bold' ] : [ 'Helvetica', 10 ],
        -anchor => 'w',
    )->pack( -side => 'left', -fill => 'both', -expand => 1 );

    my $toggle = sub {
        return unless $is_overlay_key_enabled->($key);
        $overlay_visibility{$key} = $overlay_visibility{$key} ? 0 : 1;
        if ( $key eq 'show_manual_fibonacci' && defined $engine ) {
            $engine->set_manual_fibonacci_visible( $overlay_visibility{$key} );
        }
        if ( $key =~ /^show_zz_/ && defined $engine && $engine->{price_canvas} ) {
            $engine->{price_canvas}->delete('zz_overlay');
        }
        $update_overlay_menu_state->();
        $refresh_overlays->();
    };

    for my $w ($row, $check, $txt) {
        $w->configure( -cursor => 'hand2' );
        $w->bind( '<Button-1>', $toggle );
        $w->bind( '<Enter>', sub {
            return unless $is_overlay_key_enabled->($key);
            $row->configure( -bg => $MENU_HOVER_BG );
            $check->configure( -bg => $MENU_HOVER_BG );
            $txt->configure( -bg => $MENU_HOVER_BG );
        });
        $w->bind( '<Leave>', sub {
            $row->configure( -bg => $MENU_DETAIL_BG );
            $check->configure( -bg => $MENU_DETAIL_BG );
            $txt->configure( -bg => $MENU_DETAIL_BG );
        });
    }

    push @overlay_toggle_rows, {
        key   => $key,
        row   => $row,
        check => $check,
        label => $txt,
    };
};

$add_overlay_action = sub {
    my ($label, $command) = @_;
    my $row = $overlay_detail_panel->Frame(
        -bg     => $MENU_DETAIL_BG,
        -height => 34,
    )->pack( -fill => 'x' );
    $row->packPropagate(0);

    my $spacer = $row->Label(
        -text   => ' ',
        -width  => 3,
        -bg     => $MENU_DETAIL_BG,
        -fg     => $MENU_CHECK_FG,
        -font   => [ 'Helvetica', 12, 'bold' ],
        -anchor => 'center',
    )->pack( -side => 'left', -fill => 'y' );

    my $txt = $row->Label(
        -text   => $label,
        -bg     => $MENU_DETAIL_BG,
        -fg     => $MENU_FG,
        -font   => [ 'Helvetica', 10 ],
        -anchor => 'w',
    )->pack( -side => 'left', -fill => 'both', -expand => 1 );

    my $run = sub { $command->() if $command };

    for my $w ($row, $spacer, $txt) {
        $w->configure( -cursor => 'hand2' );
        $w->bind( '<Button-1>', $run );
        $w->bind( '<Enter>', sub {
            $row->configure( -bg => $MENU_HOVER_BG );
            $spacer->configure( -bg => $MENU_HOVER_BG );
            $txt->configure( -bg => $MENU_HOVER_BG );
        });
        $w->bind( '<Leave>', sub {
            $row->configure( -bg => $MENU_DETAIL_BG );
            $spacer->configure( -bg => $MENU_DETAIL_BG );
            $txt->configure( -bg => $MENU_DETAIL_BG );
        });
    }
};

$build_overlay_detail = sub {
    my ($group) = @_;
    $_->destroy for $overlay_detail_panel->children;
    @overlay_toggle_rows = ();

    if ( $group eq 'smc' ) {
        $add_overlay_toggle->( 'Motor SMC',     'smc_enabled', 1 );
        $add_overlay_separator->();
        $add_overlay_toggle->( 'HH',            'show_hh', 0 );
        $add_overlay_toggle->( 'HL',            'show_hl', 0 );
        $add_overlay_toggle->( 'LH',            'show_lh', 0 );
        $add_overlay_toggle->( 'LL',            'show_ll', 0 );
        $add_overlay_toggle->( 'SH',            'show_sh', 0 );
        $add_overlay_toggle->( 'SL',            'show_sl', 0 );
        $add_overlay_separator->();
        $add_overlay_toggle->( 'CHoCH',           'show_choch', 0 );
        $add_overlay_toggle->( 'BOS',             'show_bos', 0 );
        $add_overlay_toggle->( 'Internal',        'show_internal_structure', 0 );
        $add_overlay_toggle->( 'External',        'show_external_structure', 0 );
        $add_overlay_toggle->( 'Order Blocks',    'show_ob', 0 );
        $add_overlay_toggle->( 'Major High/Low',  'show_major_levels', 0 );
        $add_overlay_toggle->( 'Premium/Discount','show_premium_discount', 0 );
        $add_overlay_toggle->( 'FVG (activos)',   'show_fvg', 0 );
        $add_overlay_toggle->( 'Fibonacci auto',  'show_fibonacci_auto', 0 );
        $add_overlay_toggle->( 'Market Regime',   'show_market_regime', 0 );
    } elsif ( $group eq 'liquidity' ) {
        $add_overlay_toggle->( 'Modulo completo', 'liquidity_enabled', 1 );
        $add_overlay_separator->();
        $add_overlay_toggle->( 'BSL',             'show_bsl', 0 );
        $add_overlay_toggle->( 'SSL',             'show_ssl', 0 );
        $add_overlay_toggle->( 'EQH',             'show_eqh', 0 );
        $add_overlay_toggle->( 'EQL',             'show_eql', 0 );
        $add_overlay_separator->();
        $add_overlay_toggle->( 'Liquidity Grab',  'show_grab', 0 );
        $add_overlay_toggle->( 'Sweep',           'show_sweep', 0 );
        $add_overlay_toggle->( 'Run',             'show_run', 0 );
    } elsif ( $group eq 'zigzag' ) {
        $add_overlay_toggle->( 'Direccion Externa',  'show_zz_external', 0 );
        $add_overlay_toggle->( 'Direccion Interna',  'show_zz_internal', 0 );
        $add_overlay_toggle->( 'HLDV (HH/HL/LH/LL)','show_zz_hldv',     0 );
    } elsif ( $group eq 'strategy' ) {
        $add_overlay_toggle->( 'Strategy Builder',  'strategy_enabled', 1 );
        $add_overlay_separator->();
        $add_overlay_toggle->( 'SuperTrend',        'show_supertrend', 0 );
        $add_overlay_toggle->( 'HalfTrend',         'show_halftrend', 0 );
        $add_overlay_toggle->( 'Range Filter',      'show_range_filter', 0 );
        $add_overlay_toggle->( 'Supply/Demand',     'show_supply_demand', 0 );
    } elsif ( $group eq 'volumeprofile' ) {
        $add_overlay_action->( "\x{1F4C8} Anclar / Dibujar Perfil", sub {
            $hide_overlay_menu->() if defined $hide_overlay_menu;
            $mw->after( 50, sub {
                $engine->start_vp_selection() if defined $engine;
            });
        });
        $add_overlay_separator->();
        $add_overlay_action->( 'Quitar Perfiles', sub {
            $engine->clear_vp() if defined $engine;
        });
        $add_overlay_separator->();
        $add_overlay_toggle->( 'Volume Profile',    'vp_enabled', 1 );
        $add_overlay_toggle->( 'POC',               'show_vp_poc', 0 );
        $add_overlay_toggle->( 'VAH',               'show_vp_vah', 0 );
        $add_overlay_toggle->( 'VAL',               'show_vp_val', 0 );
    } elsif ( $group eq 'vwap' ) {
        $add_overlay_action->( "\x{1F4CC} Anclar VWAP", sub {
            $hide_overlay_menu->() if defined $hide_overlay_menu;
            $mw->after( 50, sub {
                $engine->start_vwap_selection() if defined $engine;
            });
        });
        $add_overlay_separator->();
        $add_overlay_action->( 'Quitar VWAP', sub {
            $engine->clear_vwap() if defined $engine;
        });
        $add_overlay_separator->();
        $add_overlay_toggle->( 'Anchored VWAP',     'vwap_enabled', 1 );
        $add_overlay_toggle->( 'Banda 1x',          'show_vwap_band1', 0 );
        $add_overlay_toggle->( 'Banda 2x',          'show_vwap_band2', 0 );
        $add_overlay_toggle->( 'Banda 3x',          'show_vwap_band3', 0 );
    } elsif ( $group eq 'herramientas' ) {
        $add_overlay_action->( "\x{1F4C8} Dibujar Canal de Regresi\x{f3}n", sub {
            $hide_overlay_menu->() if defined $hide_overlay_menu;
            $mw->after( 50, sub {
                $engine->start_regression_channel_selection() if defined $engine;
            });
        });
        $add_overlay_separator->();
        $add_overlay_action->( 'Quitar Canal de Regresi' . "\x{f3}n", sub {
            $engine->clear_regression_channel() if defined $engine;
        });
    } else {
        $add_overlay_action->( 'Seleccionar zona', sub {
            $overlay_visibility{show_manual_fibonacci} = 1;
            $engine->set_manual_fibonacci_visible(1) if defined $engine;
            $update_overlay_menu_state->();
            $hide_overlay_menu->() if defined $hide_overlay_menu;
            $mw->after( 50, sub {
                $engine->start_manual_fibonacci_selection() if defined $engine;
            });
        });
        $add_overlay_separator->();
        $add_overlay_toggle->( 'Mostrar manual', 'show_manual_fibonacci', 0 );
        $add_overlay_toggle->( 'Mostrar auto SMC', 'show_fibonacci_auto', 0 );
        $add_overlay_separator->();
        $add_overlay_action->( 'Quitar manual', sub {
            $engine->clear_manual_fibonacci() if defined $engine;
            $overlay_visibility{show_manual_fibonacci} = 1;
            $update_overlay_menu_state->();
        });
    }

    $update_overlay_menu_state->();
};

$show_overlay_group = sub {
    my ($group) = @_;
    $overlay_active_group = $group;
    $paint_overlay_categories->();
    $build_overlay_detail->($group);
};

$overlay_btn = $toolbar->Button(
    -text             => $overlay_button_text,
    -bg               => '#2a2d3e',
    -fg               => '#ffffff',
    -relief           => 'flat',
    -padx             => 10,
    -pady             => 3,
    -activebackground => '#3a3d4e',
    -activeforeground => '#ffffff',
    -font             => [ 'Helvetica', 9, 'bold' ],
    -command          => sub { $toggle_overlay_menu->(); },
)->pack( -side => 'left', -padx => 8, -pady => 2 );

$overlay_menu_panel = $mw->Frame(
    -bg                 => $MENU_BORDER,
    -borderwidth        => 1,
    -relief             => 'solid',
    -highlightthickness => 0,
);

$overlay_main_panel = $overlay_menu_panel->Frame(
    -bg     => $MENU_PANEL_BG,
    -width  => $OVERLAY_COL_W,
    -height => $OVERLAY_MENU_H,
)->pack( -side => 'left', -fill => 'y' );
$overlay_main_panel->packPropagate(0);

$overlay_detail_panel = $overlay_menu_panel->Frame(
    -bg     => $MENU_DETAIL_BG,
    -width  => $OVERLAY_COL_W,
    -height => $OVERLAY_MENU_H,
)->pack( -side => 'left', -fill => 'both' );
$overlay_detail_panel->packPropagate(0);

my $add_overlay_category = sub {
    my ($label, $group) = @_;
    my $row = $overlay_main_panel->Frame(
        -bg     => $MENU_PANEL_BG,
        -height => 44,
    )->pack( -fill => 'x' );
    $row->packPropagate(0);

    my $txt = $row->Label(
        -text   => $label,
        -bg     => $MENU_PANEL_BG,
        -fg     => $MENU_FG,
        -font   => [ 'Helvetica', 10 ],
        -anchor => 'w',
        -padx   => 14,
    )->pack( -side => 'left', -fill => 'both', -expand => 1 );
    my $arrow = $row->Label(
        -text   => '>',
        -bg     => $MENU_PANEL_BG,
        -fg     => '#c4cad3',
        -font   => [ 'Helvetica', 12, 'bold' ],
        -width  => 4,
        -anchor => 'center',
    )->pack( -side => 'right', -fill => 'y' );

    my $select = sub { $show_overlay_group->($group); };
    for my $w ($row, $txt, $arrow) {
        $w->configure( -cursor => 'hand2' );
        $w->bind( '<Button-1>', $select );
        $w->bind( '<Enter>', sub {
            return if $overlay_active_group eq $group;
            $row->configure( -bg => $MENU_HOVER_BG );
            $txt->configure( -bg => $MENU_HOVER_BG );
            $arrow->configure( -bg => $MENU_HOVER_BG );
        });
        $w->bind( '<Leave>', sub { $paint_overlay_categories->(); } );
    }

    push @overlay_category_rows, {
        group   => $group,
        widgets => [ $row, $txt, $arrow ],
    };
};

$add_overlay_category->( 'SMC',          'smc' );
$add_overlay_category->( 'Liquidez',     'liquidity' );
$add_overlay_category->( 'ZigZag',       'zigzag' );
$add_overlay_category->( 'Herramientas', 'herramientas' );
$add_overlay_category->( 'Fibonacci',    'fibonacci' );
$add_overlay_category->( 'Strategy',     'strategy' );
$add_overlay_category->( 'Vol. Profile', 'volumeprofile' );
$add_overlay_category->( 'VWAP',         'vwap' );

$hide_overlay_menu = sub {
    return unless $overlay_menu_visible;
    $overlay_menu_panel->placeForget();
    $overlay_menu_visible = 0;
    $overlay_btn->configure( -bg => '#2a2d3e' );
};

$show_overlay_menu = sub {
    $show_overlay_group->($overlay_active_group);

    my $menu_w = $OVERLAY_MENU_W;
    my $menu_h = $OVERLAY_MENU_H;
    my $x = $overlay_btn->rootx - $mw->rootx;
    my $y = $toolbar->rooty - $mw->rooty + ( $toolbar->height || 32 ) + 4;
    my $window_w = $mw->width || 1200;
    my $window_h = $mw->height || 800;

    $x = $window_w - $menu_w - 6 if $x + $menu_w > $window_w - 6;
    $x = 6 if $x < 6;
    $y = $window_h - $menu_h - 6 if $y + $menu_h > $window_h - 6;
    $y = 6 if $y < 6;

    $overlay_menu_panel->place(
        -x      => $x,
        -y      => $y,
        -width  => $menu_w,
        -height => $menu_h,
    );
    $overlay_menu_panel->raise();
    $overlay_menu_visible = 1;
    $overlay_btn->configure( -bg => '#354052' );
};

$toggle_overlay_menu = sub {
    if ($overlay_menu_visible) {
        $hide_overlay_menu->();
    } else {
        $show_overlay_menu->();
    }
};

$show_overlay_group->('smc');

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
    } elsif ( $state eq 'selecting' ) {
        $replay_btn->configure( -text => 'CANCEL RP', -fg => '#83a9ff' );
        $play_btn->configure(   -text => '>',         -fg => '#b2b5be' ) if defined $play_btn;
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
        } elsif ( $engine->{replay_selecting} ) {
            $engine->cancel_replay_selection();
        } else {
            $engine->begin_replay_selection();
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
$engine->set_market_regime_indicator($regime_ind);
$engine->set_strategy_indicator($strategy_ind);
$engine->set_vp_indicator($vp_ind);
$engine->set_vwap_indicator($vwap_ind);
$engine->add_overlay( Market::Overlays::ZigZagDirection->new(
    indicator  => $zz_ind,
    visibility => \%overlay_visibility,
) );
$engine->add_overlay( Market::Overlays::SMC_Structures->new(
    indicator        => $smc_ind,
    regime_indicator => $regime_ind,
    visibility       => \%overlay_visibility,
) );
$engine->add_overlay( Market::Overlays::Liquidity->new(
    indicator  => $lq_ind,
    visibility => \%overlay_visibility,
) );
$engine->add_overlay( Market::Overlays::Strategy_Builder->new(
    indicator  => $strategy_ind,
    visibility => \%overlay_visibility,
) );
$engine->add_overlay( Market::Overlays::VolumeProfile->new(
    indicator  => $vp_ind,
    visibility => \%overlay_visibility,
) );
$engine->add_overlay( Market::Overlays::AnchoredVWAP->new(
    indicator  => $vwap_ind,
    visibility => \%overlay_visibility,
) );

$engine->set_scale_mode_callback( \&_update_mode_btn );
$engine->set_replay_callback( \&_update_replay_ui );
$engine->bind_events();

# Pan horizontal + vertical (Ev('X','Y') = coords globales de pantalla)
# El pan vertical solo actua en modo manual (ChartEngine lo verifica internamente)
$mw->bind( '<ButtonPress-1>',   [ sub { $engine->drag_start( $_[1], $_[2] ) }, Ev('X'), Ev('Y') ] );
$mw->bind( '<ButtonRelease-1>', [ sub { $engine->drag_end( $_[1], $_[2] ) }, Ev('X'), Ev('Y') ] );
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
$mw->bind( '<End>',     sub { $engine->goto_last() } );   # ultima vela con margen derecho

$mw->update();    # ensure canvas dimensions are resolved
$engine->render();

# Re-render on window resize
$price_canvas->bind( '<Configure>', sub { $engine->request_render(); } );
$volume_canvas->bind( '<Configure>', sub { $engine->request_render(); } );
$atr_canvas->bind(   '<Configure>', sub { $engine->request_render(); } );

MainLoop();
