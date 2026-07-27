#!/usr/bin/perl
# ============================================================
# Extractor de características para modelo predictivo de Fantasmas
# Uso:
#   perl extract_features.pl <entrada.csv> <salida.csv>
# Ejemplo:
#   perl extract_features.pl ../2026_03_mayo.csv features_train.csv
#   perl extract_features.pl ../2026_03_julio.csv features_test.csv
# ============================================================
use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";

use POSIX qw(floor);
use List::Util qw(min max sum);

# ---- Reutilizamos los indicadores ya implementados ----
use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;
use Market::Indicators::PivotMissedReversal;
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;
use Market::Indicators::ZigZagDirection;

# ============================================================
# CONFIGURACIÓN
# ============================================================
my $CSV_IN         = $ARGV[0] // '../2026_03_mayo.csv';
my $CSV_OUT        = $ARGV[1] // 'features_train.csv';

my $ATR_PERIOD     = 14;
my $GHOST_LENGTH   = 20;   # largo del PivotMissedReversal
my $ZZ_EXT_LEN     = 150;  # largo del ZigZag externo
my $EMA_VOL_PER    = 9;    # EMA de volumen
my $RSI_PERIOD     = 14;
my $PIP            = 0.25; # NQ tick size = 0.25 puntos = 1 pip

# Ventanas de predicción (en barras de 1 minuto)
my @WINDOWS = (3, 5, 10, 15);

# ============================================================
# UTILIDADES — parse timestamp
# ============================================================
sub parse_ts {
    my ($ts) = @_;
    return 0 unless $ts =~
        /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})([-+])(\d{2}):(\d{2})$/;
    my ($y,$mo,$d,$h,$mi,$s,$sign,$tzh,$tzm) = ($1,$2,$3,$4,$5,$6,$7,$8,$9);
    my @dim  = (0,31,59,90,120,151,181,212,243,273,304,334);
    my $leap = ($y%4==0 && ($y%100!=0 || $y%400==0)) ? 1 : 0;
    my $doy  = $dim[$mo-1] + ($mo>2 ? $leap : 0) + $d;
    my $days = ($y-1970)*365 + int(($y-1969)/4) - int(($y-1901)/100)
             + int(($y-1601)/400) + $doy - 1;
    my $utc  = $days*86400 + $h*3600 + $mi*60 + $s;
    return $utc - ($tzh*3600 + $tzm*60) * ($sign eq '+' ? 1 : -1);
}

# ============================================================
# CARGA DE DATOS
# ============================================================
sub load_csv {
    my ($file) = @_;
    open my $fh, '<', $file or die "No se puede abrir $file: $!";
    <$fh>; # saltar cabecera
    my @bars;
    while (my $line = <$fh>) {
        chomp $line;
        my ($ts,$open,$high,$low,$close,$vol) = split /,/, $line;
        next unless defined $vol && $vol ne '';
        push @bars, {
            datetime => $ts,
            time     => parse_ts($ts),  # epoch numerico (requerido por MarketData.pm)
            open     => $open  + 0,
            high     => $high  + 0,
            low      => $low   + 0,
            close    => $close + 0,
            volume   => $vol   + 0,
        };
    }
    close $fh;
    return \@bars;
}

# ============================================================
# INDICADORES PUROS (sin módulos externos — más rápido)
# ============================================================

sub compute_atr {
    my ($bars, $per) = @_;
    my @atr = (0) x @$bars;
    my $prev;
    my $sum = 0;
    my @trs;
    for my $i (0..$#$bars) {
        my $tr = $bars->[$i]{high} - $bars->[$i]{low};
        if (defined $prev) {
            my $a = abs($bars->[$i]{high} - $prev);
            my $b = abs($bars->[$i]{low}  - $prev);
            $tr = $a if $a > $tr;
            $tr = $b if $b > $tr;
        }
        push @trs, $tr;
        $prev = $bars->[$i]{close};
        if ($i < $per - 1) {
            $sum += $tr;
        } elsif ($i == $per - 1) {
            $sum += $tr;
            $atr[$i] = $sum / $per;
        } else {
            $atr[$i] = ($atr[$i-1] * ($per-1) + $tr) / $per;
        }
    }
    return \@atr;
}

sub compute_ema {
    my ($vals, $per) = @_;
    my @ema = (0) x @$vals;
    my $k   = 2 / ($per + 1);
    my $sum = 0;
    for my $i (0..$#$vals) {
        if ($i < $per - 1) { $sum += $vals->[$i]; }
        elsif ($i == $per - 1) {
            $sum += $vals->[$i];
            $ema[$i] = $sum / $per;
        } else {
            $ema[$i] = $vals->[$i] * $k + $ema[$i-1] * (1 - $k);
        }
    }
    return \@ema;
}

sub compute_rsi {
    my ($bars, $per) = @_;
    my @rsi  = (50) x @$bars;
    my ($ag, $al) = (0, 0);
    for my $i (1..$#$bars) {
        my $d = $bars->[$i]{close} - $bars->[$i-1]{close};
        my ($g, $l) = ($d > 0 ? $d : 0, $d < 0 ? -$d : 0);
        if ($i <= $per) {
            $ag = ($ag * ($i-1) + $g) / $i;
            $al = ($al * ($i-1) + $l) / $i;
        } else {
            $ag = ($ag * ($per-1) + $g) / $per;
            $al = ($al * ($per-1) + $l) / $per;
        }
        $rsi[$i] = $al == 0 ? 100 : 100 - 100 / (1 + $ag / $al) if $i >= $per;
    }
    return \@rsi;
}

# ---- Detectar pivot high/low (mismo algoritmo que PivotMissedReversal) ----
sub _is_ph {
    my ($bars, $c, $k) = @_;
    return 0 if $c < $k || $c + $k > $#$bars;
    my $p = $bars->[$c]{high};
    for my $i ($c-$k..$c+$k) {
        next if $i == $c;
        return 0 if $bars->[$i]{high} > $p || ($bars->[$i]{high} == $p && $i > $c);
    }
    return 1;
}
sub _is_pl {
    my ($bars, $c, $k) = @_;
    return 0 if $c < $k || $c + $k > $#$bars;
    my $p = $bars->[$c]{low};
    for my $i ($c-$k..$c+$k) {
        next if $i == $c;
        return 0 if $bars->[$i]{low} < $p || ($bars->[$i]{low} == $p && $i > $c);
    }
    return 1;
}

# ============================================================
# DETECTOR DE FANTASMAS (replica PivotMissedReversal.pm)
# ============================================================
sub detect_ghosts {
    my ($bars, $len) = @_;
    my (@ghosts);
    my %seen;
    my ($tmax, $tmin, $tmax_i, $tmin_i);
    my ($fmax, $fmin, $fmax_i, $fmin_i);
    my ($ltype);

    for my $n (0..$#$bars) {
        my $c = $n - $len;
        next if $c < 0;
        my ($hi, $lo) = ($bars->[$c]{high}, $bars->[$c]{low});

        if (!defined $tmax || $hi > $tmax) { ($tmax,$tmax_i)=($hi,$c); ($fmin,$fmin_i)=($lo,$c) }
        if (!defined $tmin || $lo < $tmin) { ($tmin,$tmin_i)=($lo,$c); ($fmax,$fmax_i)=($hi,$c) }
        $fmin=$lo, $fmin_i=$c if !defined $fmin || $lo < $fmin;
        $fmax=$hi, $fmax_i=$c if !defined $fmax || $hi > $fmax;
        next if $c < $len;

        my $ph = _is_ph($bars, $c, $len);
        my $pl = _is_pl($bars, $c, $len);
        if ($ph && $pl) {
            if    (!defined $ltype)         { $ph = $pl = 0 }
            elsif ($ltype eq 'high')        { $ph = 0 }
            else                            { $pl = 0 }
        }

        my $add = sub {
            my ($type,$idx,$price) = @_;
            my $key = "$type:$idx:$n";
            return if $seen{$key}++;
            push @ghosts, { type=>$type, index=>$idx, price=>$price, confirmed_at=>$n };
        };

        if ($ph) {
            if (defined $ltype) {
                if    ($ltype eq 'high')                        { $add->('low', $tmin_i, $tmin) }
                elsif (defined $tmax && $hi < $tmax)           { $add->('high',$tmax_i,$tmax); $add->('low',$fmin_i,$fmin) }
            } elsif (defined $tmax && $hi < $tmax)             { $add->('high',$tmax_i,$tmax); $add->('low',$fmin_i,$fmin) }
            $ltype = 'high';
            ($tmax,$tmin,$tmax_i,$tmin_i) = ($hi,$hi,$c,$c);
            ($fmax,$fmin,$fmax_i,$fmin_i) = ($hi,$hi,$c,$c);
        } elsif ($pl) {
            if (defined $ltype) {
                if    ($ltype eq 'low')                         { $add->('high',$tmax_i,$tmax) }
                elsif (defined $tmin && $lo > $tmin)           { $add->('low',$tmin_i,$tmin);  $add->('high',$fmax_i,$fmax) }
            } elsif (defined $tmax)                             { $add->('high',$tmax_i,$tmax) }
            $ltype = 'low';
            ($tmax,$tmin,$tmax_i,$tmin_i) = ($lo,$lo,$c,$c);
            ($fmax,$fmin,$fmax_i,$fmin_i) = ($lo,$lo,$c,$c);
        }
    }
    return [ sort { $a->{confirmed_at} <=> $b->{confirmed_at} } @ghosts ];
}

# ============================================================
# CONTEO DE RASTROS (targets)
# Rastro = barra futura donde el precio vuelve a tocar
# el nivel del fantasma (high >= precio para fantasma alto,
# low <= precio para fantasma bajo)
# ============================================================
sub count_traces {
    my ($bars, $ghost, $from, $window) = @_;
    my $to    = min($from + $window - 1, $#$bars);
    return -1 if $to < $from;   # no hay datos suficientes
    my $price = $ghost->{price};
    my $count = 0;
    for my $i ($from..$to) {
        if ($ghost->{type} eq 'high') { $count++ if $bars->[$i]{high}  >= $price }
        else                          { $count++ if $bars->[$i]{low}   <= $price }
    }
    return $count;
}

# ============================================================
# PRE-CALCULAR SWING HIGHS/LOWS (pivot, k=5 vecinos)
# almacenados con su índice para búsquedas rápidas
# ============================================================
sub precompute_swings {
    my ($bars, $k) = @_;
    my (@sh_idx, @sl_idx);
    for my $i ($k..$#$bars-$k) {
        push @sh_idx, $i if _is_ph($bars, $i, $k);
        push @sl_idx, $i if _is_pl($bars, $i, $k);
    }
    return (\@sh_idx, \@sl_idx);
}

# Distancia en pips al swing high más cercano por encima y por debajo
sub dist_to_swings {
    my ($bars, $sh_idx, $sl_idx, $cur, $lookback) = @_;
    my $close   = $bars->[$cur]{close};
    my $min_bar = max(0, $cur - $lookback);
    my ($nearest_above, $nearest_below) = (undef, undef);
    # buscar desde cur hacia atrás en $sh_idx (están ordenados)
    for my $i (reverse @$sh_idx) {
        last if $i < $min_bar;
        next if $i >= $cur;
        my $p = $bars->[$i]{high};
        if ($p > $close) { $nearest_above = $p unless defined $nearest_above && $p > $nearest_above }
        else             { last }  # ya son menores, parar (no optimizable directo, pero son pocos)
    }
    # bug fix: buscar todos dentro del rango
    $nearest_above = undef; $nearest_below = undef;
    for my $i (@$sh_idx) {
        next if $i < $min_bar || $i >= $cur;
        my $p = $bars->[$i]{high};
        if ($p > $close) {
            $nearest_above = $p if !defined $nearest_above || $p < $nearest_above;
        }
    }
    for my $i (@$sl_idx) {
        next if $i < $min_bar || $i >= $cur;
        my $p = $bars->[$i]{low};
        if ($p < $close) {
            $nearest_below = $p if !defined $nearest_below || $p > $nearest_below;
        }
    }
    my $da = defined $nearest_above ? ($nearest_above - $close) / $PIP : 999;
    my $db = defined $nearest_below ? ($close - $nearest_below) / $PIP : 999;
    return ($da, $db);
}

# Contar cuántos swings hay en rango ±N*ATR
sub count_swings_near {
    my ($bars, $sh_idx, $sl_idx, $cur, $lookback, $atr_band) = @_;
    my $close   = $bars->[$cur]{close};
    my $atr_c   = $atr_band;
    my $min_bar = max(0, $cur - $lookback);
    my ($nsh, $nsl) = (0, 0);
    for my $i (@$sh_idx) {
        next if $i < $min_bar || $i >= $cur;
        $nsh++ if abs($bars->[$i]{high} - $close) <= 5 * $atr_c;
    }
    for my $i (@$sl_idx) {
        next if $i < $min_bar || $i >= $cur;
        $nsl++ if abs($bars->[$i]{low} - $close) <= 5 * $atr_c;
    }
    return ($nsh, $nsl);
}

# ============================================================
# MAIN
# ============================================================
print "Cargando datos de $CSV_IN...\n";
my $bars = load_csv($CSV_IN);
my $N    = scalar @$bars;
print "  $N barras cargadas.\n";

print "Calculando ATR($ATR_PERIOD), EMA_vol($EMA_VOL_PER), RSI($RSI_PERIOD)...\n";
my $atr     = compute_atr($bars, $ATR_PERIOD);
my @vols    = map { $_->{volume} } @$bars;
my $vol_ema = compute_ema(\@vols, $EMA_VOL_PER);
my @closes  = map { $_->{close} } @$bars;
my $rsi     = compute_rsi($bars, $RSI_PERIOD);

print "Pre-calculando swing highs/lows (k=5)...\n";
my ($sh5, $sl5) = precompute_swings($bars, 5);
print "  SH: " . scalar(@$sh5) . "  SL: " . scalar(@$sl5) . "\n";

# Swings con k=10 para contexto de 1h (mayor escala)
my ($sh10, $sl10) = precompute_swings($bars, 10);

print "Detectando fantasmas (PivotMissedReversal, length=$GHOST_LENGTH)...\n";
my $ghosts = detect_ghosts($bars, $GHOST_LENGTH);
print "  Fantasmas encontrados: " . scalar(@$ghosts) . "\n";

# Usamos Market:: para BOS/CHoCH y FVG/OB (indicadores ya implementados)
print "Cargando market data para indicadores avanzados...\n";
my $market = Market::MarketData->new();
$market->add_candle($_) for @$bars;
$market->build_timeframes();
$market->build_volume_index();

my $ind_mgr = Market::IndicatorManager->new();
$ind_mgr->register('ATR', Market::Indicators::ATR->new($ATR_PERIOD));
my $zz_ind = Market::Indicators::ZigZagDirection->new(
    external_length     => $ZZ_EXT_LEN,
    internal_resolution => 15,
    internal_period     => 2,
);
$ind_mgr->register('ZigZagDirection', $zz_ind);
$ind_mgr->compute_all($market);

my $lq_ind = Market::Indicators::Liquidity->new(
    depth          => 3,
    external_depth => $ZZ_EXT_LEN,
    atr_period     => $ATR_PERIOD,
);
$lq_ind->compute_all($market);

my $smc_ind = Market::Indicators::SMC_Structures->new(depth => 5, external_depth => 25);
$smc_ind->set_liquidity_indicator($lq_ind);
$smc_ind->compute_all($market);

print "Indicadores listos. Extrayendo features...\n";

# Estructuras de liquidez para búsqueda rápida
my $lq_levels  = $lq_ind->get_levels()     // [];
my $bos_events = $smc_ind->get_bos_events() // [];
my $choch_ev   = $smc_ind->get_choch_events() // [];
my $fvg_zones  = $smc_ind->get_fvg_zones() // [];
my $ob_zones   = $smc_ind->get_ob_zones() // [];
my $ext_pivots = $zz_ind->get_external_pivots() // [];

# Helper: distancia en pips al nivel más cercano de una lista (causal: confirmed_at <= cur)
sub nearest_level_dist {
    my ($levels, $cur, $price_field, $confirmed_field, $close) = @_;
    $confirmed_field //= 'confirmed_at';
    my ($above, $below) = (undef, undef);
    for my $ev (@$levels) {
        my $cf = $ev->{$confirmed_field} // $ev->{index} // 9999999;
        next if $cf > $cur;
        my $p = $ev->{$price_field} // $ev->{level} // $ev->{price};
        next unless defined $p;
        if ($p > $close) { $above = $p if !defined $above || $p < $above }
        else             { $below = $p if !defined $below || $p > $below }
    }
    my $da = defined $above ? ($above - $close) / $PIP : 999;
    my $db = defined $below ? ($close - $below) / $PIP : 999;
    return ($da, $db);
}

# Helper: ZigZag externo — último high y último low confirmados antes de cur
sub last_zz_high_low {
    my ($pivots, $cur) = @_;
    my ($last_h, $last_l) = (undef, undef);
    for my $p (@$pivots) {
        next if ($p->{confirmed_at} // $p->{index} // 9999999) > $cur;
        next if ($p->{index} // 0) > $cur;
        if (($p->{type}//'') eq 'high') { $last_h = $p->{price} }
        else                            { $last_l = $p->{price} }
    }
    return ($last_h, $last_l);
}

# Helper: niveles Fibonacci del último swing ZigZag
sub fib_levels {
    my ($high, $low) = @_;
    return () unless defined $high && defined $low;
    my $range = $high - $low;
    return () if $range <= 0;
    return map { $low + $range * $_ } (0.236, 0.382, 0.5, 0.618, 0.786);
}

sub nearest_fib_dist {
    my ($high, $low, $close) = @_;
    my @fibs = fib_levels($high, $low);
    return 999 unless @fibs;
    my $min_dist = min(map { abs($_ - $close) } @fibs);
    return $min_dist / $PIP;
}

# ============================================================
# ESCRIBIR CSV DE SALIDA
# ============================================================
open my $out, '>', $CSV_OUT or die "No se puede escribir $CSV_OUT: $!";

# Columnas de features (sin metadata de tiempo)
# Las columnas datetime/epoch son metadatos (NO se usan en entrenamiento)
my @feat_cols = qw(
    ghost_type
    dist_ghost_pips
    atr
    body_atr upper_wick_atr lower_wick_atr
    rsi close_ret1_atr close_ret5_atr close_ret15_atr
    vol vol_ema9 vol_ratio
    dist_sh5_above dist_sl5_below
    n_sh5_near n_sl5_near
    dist_sh10_above dist_sl10_below
    dist_bsl_above dist_ssl_below
    dist_bos_above dist_bos_below
    dist_fvg_above dist_fvg_below
    dist_ob_above dist_ob_below
    dist_fib_pips
    zz_high_dist_pips zz_low_dist_pips
);
my @target_cols = map { "traces_${_}m" } @WINDOWS;
my @meta_cols   = qw(datetime epoch ghost_index);

print $out join(',', @meta_cols, @feat_cols, @target_cols) . "\n";

my $written = 0;
my $skipped = 0;

for my $g (@$ghosts) {
    my $cur = $g->{confirmed_at};

    # Necesitamos historia suficiente y barras futuras para etiquetar
    next if $cur < $ATR_PERIOD + $GHOST_LENGTH + 15;
    next if $cur + $WINDOWS[-1] > $#$bars;

    my $atr_c = $atr->[$cur];
    next unless $atr_c > 0;

    my $bar   = $bars->[$cur];
    my $close = $bar->{close};
    my $open  = $bar->{open};
    my $high  = $bar->{high};
    my $low   = $bar->{low};
    my $vol   = $bar->{volume};

    # ---- Features ----
    my $ghost_type = $g->{type} eq 'high' ? 1 : 0;
    my $dist_ghost = ($close - $g->{price}) / $PIP;

    my $body       = abs($close - $open) / $atr_c;
    my $uwick      = ($high - ($close > $open ? $close : $open)) / $atr_c;
    my $lwick      = (($close < $open ? $close : $open) - $low)  / $atr_c;

    my $rsi_c   = $rsi->[$cur];
    my $ret1    = $cur >= 1  ? ($close - $bars->[$cur-1]{close})  / $atr_c : 0;
    my $ret5    = $cur >= 5  ? ($close - $bars->[$cur-5]{close})  / $atr_c : 0;
    my $ret15   = $cur >= 15 ? ($close - $bars->[$cur-15]{close}) / $atr_c : 0;

    my $ve      = $vol_ema->[$cur] || 1;
    my $vr      = $vol / $ve;

    # Swings corto plazo (k=5, lookback=60 barras = ~1h)
    my ($d_sh5, $d_sl5) = dist_to_swings($bars, $sh5, $sl5, $cur, 60);
    my ($n_sh5, $n_sl5) = count_swings_near($bars, $sh5, $sl5, $cur, 60, $atr_c);

    # Swings largo plazo (k=10, lookback=240 barras = ~4h)
    my ($d_sh10, $d_sl10) = dist_to_swings($bars, $sh10, $sl10, $cur, 240);

    # BSL/SSL desde Liquidity
    my ($d_bsl, $d_ssl) = nearest_level_dist($lq_levels, $cur, 'price', 'confirmed_at', $close);

    # BOS/CHoCH desde SMC
    my @bos_choch = (@$bos_events, @$choch_ev);
    my ($d_bos_a, $d_bos_b) = nearest_level_dist(\@bos_choch, $cur, 'level', 'confirmed_at', $close);

    # FVG — usamos mid del gap
    my @fvg_mid = map {
        my $top = $_->{top} // $_->{high} // 0;
        my $bot = $_->{bottom} // $_->{low} // 0;
        { price => ($top+$bot)/2, confirmed_at => $_->{confirmed_at} // $_->{index} // 0 }
    } @$fvg_zones;
    my ($d_fvg_a, $d_fvg_b) = nearest_level_dist(\@fvg_mid, $cur, 'price', 'confirmed_at', $close);

    # Order Blocks — mid del bloque
    my @ob_mid = map {
        my $top = $_->{top} // $_->{high} // 0;
        my $bot = $_->{bottom} // $_->{low} // 0;
        { price => ($top+$bot)/2, confirmed_at => $_->{confirmed_at} // $_->{index} // 0 }
    } @$ob_zones;
    my ($d_ob_a, $d_ob_b) = nearest_level_dist(\@ob_mid, $cur, 'price', 'confirmed_at', $close);

    # ZigZag externo — Fibonacci
    my ($zz_h, $zz_l) = last_zz_high_low($ext_pivots, $cur);
    my $d_fib   = nearest_fib_dist($zz_h, $zz_l, $close);
    my $d_zz_h  = defined $zz_h ? abs($zz_h - $close) / $PIP : 999;
    my $d_zz_l  = defined $zz_l ? abs($zz_l - $close) / $PIP : 999;

    # ---- Targets: contar rastros ----
    my $start = $cur + 1;
    my @traces = map { count_traces($bars, $g, $start, $_) } @WINDOWS;

    # Saltar si algún target es inválido (no hay barras)
    if (grep { $_ < 0 } @traces) { $skipped++; next }

    # ---- Escribir fila ----
    printf $out "%s,%d,%d,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.2f,%.4f,%.4f,%.4f,%.2f,%.2f,%.4f,%d,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%d,%d,%d,%d,%d,%d,%d\n",
        $bar->{datetime}, $bar->{time}, $g->{index},   # metadata
        $ghost_type, $dist_ghost,                    # ghost
        $atr_c, $body, $uwick, $lwick,               # precio
        $rsi_c, $ret1, $ret5, $ret15,                # momentum
        $vol, $ve, $vr,                              # volumen
        $n_sh5, $n_sl5, $d_sh5, $d_sl5,             # swings corto plazo
        $d_sh10, $d_sl10,                            # swings largo plazo
        $d_bsl, $d_ssl,                              # BSL/SSL
        $d_bos_a, $d_bos_b,                          # BOS/CHoCH
        $d_fvg_a, $d_fvg_b,                          # FVG
        $d_ob_a, $d_ob_b,                            # OB
        $d_fib, $d_zz_h, $d_zz_l,                   # ZigZag / Fibonacci
        @traces;                                     # targets

    $written++;
}

close $out;
printf "\nListo: %d registros escritos en %s  (%d descartados)\n",
    $written, $CSV_OUT, $skipped;
print "Columnas features: " . scalar(@feat_cols) . "\n";
print "Columnas target  : " . scalar(@target_cols) . " (traces_3m, 5m, 10m, 15m)\n";
