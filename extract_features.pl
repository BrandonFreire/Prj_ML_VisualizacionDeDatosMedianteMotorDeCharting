#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin;
use Getopt::Long qw(GetOptions);
use Time::Local qw(timegm);

use Market::MarketData;
use Market::Indicators::ATR;
use Market::Indicators::GhostsInSwings;
use Market::Indicators::Liquidity;
use Market::Indicators::SMC_Structures;
use Market::Indicators::Strategy_Builder;
use Market::Indicators::VolumeProfile;
use Market::Indicators::ZigZagDirection;
use Market::ML::GhostTargets;

# Extractor batch/headless. No importa Tk ni Market::ChartEngine: procesa cada
# marco una sola vez, indexa eventos causales y escribe sólo filas de eventos
# GhostsInSwings. Las distancias son signed: (nivel - HLC3) / pip_size.

my %opt = (
    pip_size => 0.0001,
    ghost_length => 50,
    quiet => 0,
);
GetOptions(
    'input=s'        => \$opt{input},
    'output=s'       => \$opt{output},
    'pip-size=f'     => \$opt{pip_size},
    'ghost-length=i' => \$opt{ghost_length},
    'quiet!'         => \$opt{quiet},
    'help|h'         => \$opt{help},
) or _usage(1);
_usage(0) if $opt{help};
die "--input es obligatorio\n" unless defined $opt{input} && length $opt{input};
die "--output es obligatorio\n" unless defined $opt{output} && length $opt{output};
die "--pip-size debe ser mayor que cero\n"
    unless defined($opt{pip_size}) && $opt{pip_size} > 0;

my $market = _load_market($opt{input});
die "No se encontraron velas válidas en $opt{input}\n" unless $market->size;
$market->build_timeframes;
$market->build_tf_candles('10');
$market->build_volume_index('1');

my %contexts;
for my $tf (qw(1 10 60)) {
    $contexts{$tf} = _build_context($market, $tf);
}

my $base = $contexts{'1'};
my $ghosts = Market::Indicators::GhostsInSwings->new(length => $opt{ghost_length});
$market->set_timeframe('1');
$ghosts->compute_all($market);
my $targets = Market::ML::GhostTargets->new->compute_from_indicator($ghosts);
my %targets_by_event = map { ($_->{event_id} // '') => $_ } @$targets;

my @columns = _columns();
open my $out, '>:encoding(UTF-8)', $opt{output}
    or die "No se pudo escribir $opt{output}: $!\n";
print {$out} join(',', map { _csv($_) } @columns), "\n";

my $rows = 0;
for my $event (@{ $ghosts->get_relocations }) {
    my $i = $event->{occurrence_index};
    next unless defined($i) && $i > 0;
    my $candle = $base->{candles}[$i] // next;
    my $reference_time = $base->{candles}[$i - 1]{time}; # estructura previa
    my $price = _hlc3($candle);
    next unless defined $price;

    my %row = (
        event_id => $event->{id}, event_timestamp => $event->{occurrence_time},
        event_date => _date($event->{occurrence_time}),
        event_hour => _hour($event->{occurrence_time}),
        event_minute => _minute($event->{occurrence_time}),
        event_index => $i, ghost_index => $event->{ghost_index},
        ghost_type => $event->{type}, relocation => $event->{relocation},
        ghost_price => $event->{price}, event_hlc3 => $price,
        atr_1m => $base->{atr}[$i], volume_1m => $candle->{volume},
        volume_ema9_1m => $base->{volume_ema9}[$i],
    );

    for my $tf (qw(1 10 60)) {
        my $ctx = $contexts{$tf};
        my $index = _index_at_or_before($ctx->{times}, $reference_time);
        _add_structure_features(\%row, $tf, $ctx, $index, $price, $opt{pip_size});
    }
    _add_higher_timeframe_sr(\%row, $market, $reference_time, $price, $opt{pip_size});

    my $target = $targets_by_event{$event->{id}} // {};
    for my $field (qw(Y_3m Y_5m Y_10m Y_15m complete)) {
        $row{$field} = $target->{$field};
    }
    print {$out} join(',', map { _csv($row{$_}) } @columns), "\n";
    $rows++;
}
close $out or die "No se pudo cerrar $opt{output}: $!\n";
print STDERR "Extracted $rows ghost-event rows to $opt{output}\n" unless $opt{quiet};

sub _build_context {
    my ($market, $tf) = @_;
    $market->set_timeframe($tf);
    $market->build_volume_index($tf);
    my $atr = Market::Indicators::ATR->new(14);
    $atr->compute_all($market);
    my $liquidity = Market::Indicators::Liquidity->new(depth => 3, external_depth => 25, atr_period => 14);
    $liquidity->compute_all($market);
    my $smc = Market::Indicators::SMC_Structures->new(depth => 5, external_depth => 25);
    $smc->set_liquidity_indicator($liquidity);
    $smc->compute_all($market);
    my $strategy = Market::Indicators::Strategy_Builder->new;
    $strategy->set_smc_indicator($smc);
    $strategy->compute_all($market);
    my $vp = Market::Indicators::VolumeProfile->new(mode => 'bos_choch', num_bins => 50);
    $vp->set_smc_indicator($smc);
    $vp->compute_all($market);
    my $zz = Market::Indicators::ZigZagDirection->new(external_length => 50, internal_resolution => 15, internal_period => 2);
    $zz->compute_all($market);
    my $candles = $market->get_active_candles;
    return {
        candles => $candles, times => [ map { $_->{time} } @$candles ],
        atr => $atr->get_values, volume_ema9 => _ema9($candles),
        liquidity => $liquidity, smc => $smc, strategy => $strategy,
        vp => $vp, zz => $zz,
    };
}

sub _add_structure_features {
    my ($row, $tf, $ctx, $index, $price, $pip) = @_;
    my $prefix = "tf${tf}_";
    return _blank_tf($row, $tf) if !defined($index) || $index < 0;
    my $smc = $ctx->{smc};
    my @obs = grep { _available($_, $index) } @{ $smc->get_ob_zones // [] };
    _zone($row, $prefix . 'ob', \@obs, $price, $pip);
    my @fvgs = grep { _available($_, $index) } @{ $smc->get_fvg_zones // [] };
    _zone($row, $prefix . 'fvg', \@fvgs, $price, $pip);

    my $pivots = $ctx->{zz}->get_external_pivots_until($index);
    my @fib = _fib_levels($pivots);
    _nearest($row, $prefix . 'fib_dist_pips', \@fib, $price, $pip);
    _vwap($row, $prefix, $ctx->{candles}, $pivots, $index, $price, $pip);

    # Sólo perfiles cerrados antes de la vela de referencia: POC/VAH/VAL no
    # usan volumen futuro de un impulso aún abierto.
    my @profiles = grep { defined($_->{end_idx}) && $_->{end_idx} <= $index }
        @{ $ctx->{vp}->get_profiles // [] };
    my $profile = @profiles ? $profiles[-1] : undef;
    for my $field (qw(poc vah val)) {
        $row->{$prefix . "vp_${field}_dist_pips"} = $profile && defined($profile->{$field})
            ? _pips($profile->{$field}, $price, $pip) : undef;
    }

    my @structure = (
        grep { _available($_, $index) } @{ $smc->get_bos_events // [] },
        grep { _available($_, $index) } @{ $smc->get_choch_events // [] },
    );
    _nearest($row, $prefix . 'bos_choch_dist_pips',
        [ grep { defined } map { $_->{level} // $_->{price} } @structure ], $price, $pip);

    my $levels = $ctx->{liquidity}->get_levels // [];
    my @eq = map { $_->{eq_price} }
        grep { ($_->{is_eqh} || $_->{is_eql}) && ($_->{eq_confirmed_at} // 9_999_999) <= $index } @$levels;
    _nearest($row, $prefix . 'eqh_eql_dist_pips', \@eq, $price, $pip);
    my @resolved = map { $_->{price} }
        grep { ($_->{classification} // '') =~ /^(?:SWEEP|GRAB|BIG_GRAB|RUN)$/
            && ($_->{resolved_at} // 9_999_999) <= $index } @$levels;
    _nearest($row, $prefix . 'sweep_grab_run_dist_pips', \@resolved, $price, $pip);

    my @sd = (
        grep { _available($_, $index) } @{ $ctx->{strategy}->get_supply_zones // [] },
        grep { _available($_, $index) } @{ $ctx->{strategy}->get_demand_zones // [] },
    );
    _zone($row, $prefix . 'supply_demand', \@sd, $price, $pip);
    my @channels = grep { _available($_, $index) } @{ $ctx->{strategy}->get_trend_channels // [] };
    _channel($row, $prefix . 'channel', \@channels, $index, $price, $pip);
}

sub _zone {
    my ($row, $name, $items, $price, $pip) = @_;
    my @zones = grep { defined($_->{top}) && defined($_->{bottom}) } @$items;
    my ($best) = sort {
        abs((($a->{top} + $a->{bottom}) / 2) - $price) <=> abs((($b->{top} + $b->{bottom}) / 2) - $price)
    } @zones;
    $row->{"${name}_dist_pips"} = $best ? _pips(($best->{top} + $best->{bottom}) / 2, $price, $pip) : undef;
    $row->{"${name}_width_pips"} = $best ? abs($best->{top} - $best->{bottom}) / $pip : undef;
}

sub _nearest {
    my ($row, $key, $levels, $price, $pip) = @_;
    my @values = grep { defined($_) && $_ =~ /^-?(?:\d+(?:\.\d*)?|\.\d+)$/ } @$levels;
    my ($nearest) = sort { abs($a - $price) <=> abs($b - $price) } @values;
    $row->{$key} = defined($nearest) ? _pips($nearest, $price, $pip) : undef;
}

sub _vwap {
    my ($row, $prefix, $candles, $pivots, $index, $price, $pip) = @_;
    my @known = grep { ($_->{confirmed_at} // 9_999_999) <= $index } @$pivots;
    my $anchor = @known >= 2 ? $known[-2]{index} : undef; # penúltimo pivote externo
    for my $key (qw(vwap_dist_pips vwap_band1_dist_pips vwap_band2_dist_pips)) { $row->{$prefix . $key} = undef }
    return unless defined($anchor) && $anchor >= 0 && $anchor <= $index;
    my ($weight, $mean, $m2) = (0, 0, 0);
    for my $i ($anchor .. $index) {
        my $c = $candles->[$i] // next;
        next unless defined($c->{volume}) && $c->{volume} > 0;
        my $typical = _hlc3($c);
        my $next_weight = $weight + $c->{volume};
        my $delta = $typical - $mean;
        my $next_mean = $mean + $c->{volume} / $next_weight * $delta;
        $m2 += $c->{volume} * $delta * ($typical - $next_mean);
        ($weight, $mean) = ($next_weight, $next_mean);
    }
    return unless $weight > 0;
    my $sd = $m2 > 0 ? sqrt($m2 / $weight) : 0;
    $row->{$prefix . 'vwap_dist_pips'} = _pips($mean, $price, $pip);
    $row->{$prefix . 'vwap_band1_dist_pips'} = _pips($mean + $sd, $price, $pip);
    $row->{$prefix . 'vwap_band2_dist_pips'} = _pips($mean + 2 * $sd, $price, $pip);
}

sub _channel {
    my ($row, $name, $channels, $index, $price, $pip) = @_;
    my ($channel) = sort { abs(($a->{center_y2} // 0) - $price) <=> abs(($b->{center_y2} // 0) - $price) } @$channels;
    $row->{"${name}_dist_pips"} = undef;
    $row->{"${name}_width_pips"} = undef;
    return unless $channel;
    my $from = $channel->{start_index};
    my $slope = $channel->{slope_per_index};
    return unless defined($from) && defined($slope) && defined($channel->{lower_y1}) && defined($channel->{upper_y1});
    my $lower = $channel->{lower_y1} + $slope * ($index - $from);
    my $upper = $channel->{upper_y1} + $slope * ($index - $from);
    $row->{"${name}_dist_pips"} = _pips(($lower + $upper) / 2, $price, $pip);
    $row->{"${name}_width_pips"} = abs($upper - $lower) / $pip;
}

sub _fib_levels {
    my ($pivots) = @_;
    return () unless @$pivots >= 2;
    my ($a, $b) = @{$pivots}[-2, -1];
    return () unless defined($a->{price}) && defined($b->{price});
    my $delta = $b->{price} - $a->{price};
    return map { $a->{price} + $delta * $_ } qw(0 0.236 0.382 0.5 0.618 0.786 1);
}

sub _add_higher_timeframe_sr {
    my ($row, $market, $time, $price, $pip) = @_;
    for my $spec ([240, '4h'], [1440, 'd'], [10080, 'w']) {
        my ($tf, $label) = @$spec;
        my $arr = $market->get_data->{$tf} // [];
        my $idx = _index_at_or_before([ map { $_->{time} } @$arr ], $time);
        my $previous = defined($idx) && $idx > 0 ? $arr->[$idx - 1] : undef;
        _nearest($row, "sr_${label}_dist_pips", $previous ? [$previous->{high}, $previous->{low}] : [], $price, $pip);
    }
}

sub _blank_tf {
    my ($row, $tf) = @_;
    my $prefix = "tf${tf}_";
    $row->{$prefix . $_} = undef for qw(ob_dist_pips ob_width_pips fvg_dist_pips fvg_width_pips fib_dist_pips vwap_dist_pips vwap_band1_dist_pips vwap_band2_dist_pips vp_poc_dist_pips vp_vah_dist_pips vp_val_dist_pips bos_choch_dist_pips eqh_eql_dist_pips sweep_grab_run_dist_pips supply_demand_dist_pips supply_demand_width_pips channel_dist_pips channel_width_pips);
}

sub _available {
    my ($item, $index) = @_;
    return 0 unless $item && defined $index;
    # Un nivel promovido a estructura externa sólo es observable cuando se
    # cumple también su confirmación de scope; tomar el menor adelantaría el
    # dato durante Replay/extracción histórica.
    my @marks = grep { defined($_) && $_ =~ /^\d+$/ }
        @{$item}{qw(confirmed_at scope_confirmed_at)};
    my $available_at = @marks ? (sort { $b <=> $a } @marks)[0]
        : ($item->{formed_at} // $item->{index} // 9_999_999);
    return $available_at <= $index;
}
sub _pips { return ($_[0] - $_[1]) / $_[2] }
sub _hlc3 { my ($c) = @_; return undef unless defined($c->{high}) && defined($c->{low}) && defined($c->{close}); return ($c->{high} + $c->{low} + $c->{close}) / 3 }

sub _ema9 {
    my ($candles) = @_;
    my @out; my $alpha = 2 / 10; my $ema;
    for my $i (0 .. $#$candles) { my $v = $candles->[$i]{volume} // 0; $ema = defined($ema) ? $alpha * $v + (1 - $alpha) * $ema : $v; $out[$i] = $ema }
    return \@out;
}

sub _index_at_or_before {
    my ($times, $time) = @_;
    return undef unless @$times && defined $time;
    my ($lo, $hi, $answer) = (0, $#$times, undef);
    while ($lo <= $hi) { my $mid = int(($lo + $hi) / 2); if ($times->[$mid] <= $time) { $answer = $mid; $lo = $mid + 1 } else { $hi = $mid - 1 } }
    return $answer;
}

sub _load_market {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or die "No se pudo leer $path: $!\n";
    my $header = <$fh> // die "CSV vacío: $path\n";
    chomp $header; $header =~ s/^\x{FEFF}//;
    my @head = map { lc _trim($_) } split /,/, $header, -1;
    my %col; $col{$head[$_]} = $_ for 0 .. $#head;
    my $time_col = _first_key(\%col, qw(time timestamp datetime date));
    die "CSV debe incluir columna time/timestamp\n" unless defined $time_col;
    my $market = Market::MarketData->new;
    my $line = 1;
    while (my $raw = <$fh>) {
        $line++; chomp $raw; next unless $raw =~ /\S/;
        my @v = map { _trim($_) } split /,/, $raw, -1;
        my $time = _parse_time($v[$time_col]);
        my %c = (time => $time);
        for my $field (qw(open high low close volume)) {
            my $at = $col{$field};
            die "CSV $path línea $line sin columna $field\n" unless defined $at;
            die "CSV $path línea $line: $field inválido\n" unless defined($v[$at]) && $v[$at] =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)$/;
            $c{$field} = $v[$at] + 0;
        }
        die "CSV $path línea $line: high < low\n" if $c{high} < $c{low};
        $market->add_candle(\%c);
    }
    close $fh;
    return $market;
}

sub _first_key { my ($hash, @keys) = @_; for (@keys) { return $hash->{$_} if exists $hash->{$_} } return undef }
sub _trim { my ($x) = @_; $x //= ''; $x =~ s/^\s+|\s+$//g; $x =~ s/^"|"$//g; return $x }
sub _parse_time {
    my ($value) = @_; die "timestamp vacío\n" unless defined $value && length $value;
    return int($value) if $value =~ /^\d{9,}$/;
    die "timestamp ISO inválido: $value\n" unless $value =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(Z|([+-])(\d{2}):?(\d{2}))?$/;
    my ($y,$mo,$d,$h,$mi,$s,$zone,$sign,$zh,$zm) = ($1,$2,$3,$4,$5,$6,$7,$8,$9,$10);
    my $epoch = timegm($s,$mi,$h,$d,$mo-1,$y);
    return $epoch if !defined($zone) || $zone eq 'Z';
    my $offset = $zh * 3600 + $zm * 60;
    return $epoch - ($sign eq '+' ? $offset : -$offset);
}
sub _date { my @t = gmtime($_[0] // 0); return sprintf('%04d-%02d-%02d', $t[5]+1900, $t[4]+1, $t[3]) }
sub _hour { return (gmtime($_[0] // 0))[2] }
sub _minute { return (gmtime($_[0] // 0))[1] }
sub _csv { my ($v) = @_; return '' unless defined $v; $v =~ s/"/""/g if !ref $v; return '"' . $v . '"' if "$v" =~ /[,"\r\n]/; return $v }

sub _columns {
    my @base = qw(event_id event_timestamp event_date event_hour event_minute event_index ghost_index ghost_type relocation ghost_price event_hlc3 atr_1m volume_1m volume_ema9_1m);
    my @per = qw(ob_dist_pips ob_width_pips fvg_dist_pips fvg_width_pips fib_dist_pips vwap_dist_pips vwap_band1_dist_pips vwap_band2_dist_pips vp_poc_dist_pips vp_vah_dist_pips vp_val_dist_pips bos_choch_dist_pips eqh_eql_dist_pips sweep_grab_run_dist_pips supply_demand_dist_pips supply_demand_width_pips channel_dist_pips channel_width_pips);
    push @base, map { my $tf = $_; map { "tf${tf}_$_" } @per } qw(1 10 60);
    push @base, qw(sr_4h_dist_pips sr_d_dist_pips sr_w_dist_pips Y_3m Y_5m Y_10m Y_15m complete);
    return @base;
}

sub _usage {
    my ($code) = @_;
    print STDERR "Usage: perl extract_features.pl --input DATA.csv --output features.csv --pip-size 0.0001\n";
    exit $code;
}
