#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use Getopt::Long qw(GetOptions);
use POSIX qw(strftime);
use Market::ML::RawCsv (); # reutiliza únicamente parse_iso8601_epoch; no carga el archivo.

# Extractor CLI estrictamente headless. NO importar Tk, ChartEngine ni los
# overlays: MarketData::add_candle() también es intencionadamente evitado
# porque su contrato es conservar todo el histórico en memoria.
#
# Los cálculos de los once grupos se mantienen en HeadlessLevelEngine con
# estado O(1) y ventanas acotadas. Sustituya sus reglas internas por las
# mismas fórmulas de cada indicador al consolidar la versión de producción;
# el contrato CSV y el replay lógico ya no dependen del renderizador.

my %opt = (
    input => '2026_Abril-Junio.csv', output => 'features_abril_junio.csv',
    pip_size => 0.25, pivot_length => 20, profile_bars => 500,
);
GetOptions(
    'input=s' => \$opt{input}, 'output=s' => \$opt{output},
    'pip-size=f' => \$opt{pip_size}, 'pivot-length=i' => \$opt{pivot_length},
    'profile-bars=i' => \$opt{profile_bars},
) or die "Uso: $0 --input CSV --output CSV --pip-size N\n";
die "pip-size debe ser positivo\n" unless $opt{pip_size} > 0;
die "pivot-length debe ser >= 2\n" unless $opt{pivot_length} >= 2;

open my $in, '<', $opt{input} or die "No se pudo abrir $opt{input}: $!\n";
open my $out, '>>', $opt{output} or die "No se pudo abrir $opt{output}: $!\n";
my $header = <$in> // die "CSV sin cabecera\n";
my %col = _columns($header);
for my $name (qw(time open high low close volume)) {
    die "CSV sin columna $name\n" unless exists $col{$name};
}
print {$out} _csv_line(_columns_out()) unless -s $opt{output};

my $engine = HeadlessLevelEngine->new(%opt);
my @pending;                 # como máximo eventos surgidos durante 15 minutos
my ($line_no, $rows, $events) = (1, 0, 0);
my $last_time;

while (my $line = <$in>) {
    ++$line_no;
    next if $line =~ /^\s*$/;
    my $bar = _parse_bar($line, \%col, $line_no);
    die "CSV no ordenado o con timestamp duplicado en línea $line_no\n"
        if defined($last_time) && $bar->{time} <= $last_time;
    $last_time = $bar->{time};

    # Éste es el Replay lógico: avanza una vela cerrada de 1m y devuelve los
    # fantasmas confirmados en este instante, el rastro '1' y niveles MTF.
    my $tick = $engine->feed($bar);
    my $now = $bar->{time} + 60; # timestamp de cierre de la vela 1m

    # Actualizar Y de eventos pendientes. El intervalo es (t_evento, t+h].
    if ($tick->{trace_one}) {
        for my $pending (@pending) {
            next if $now <= $pending->{event_time};
            for my $minute (3, 5, 10, 15) {
                ++$pending->{target}{$minute} if $now <= $pending->{event_time} + $minute * 60;
            }
        }
    }

    # Tomar la foto X una vez por cada ghost (pueden existir dos en la misma
    # confirmación, tal como en Ghosts_in_swings). La hash de features es
    # escalar y la cola retiene sólo quince minutos de filas pendientes.
    for my $ghost (@{ $tick->{ghosts} }) {
        ++$events;
        push @pending, {
            event_time => $now, event => $ghost, index => $tick->{index},
            price => _hlc3($bar), features => $tick->{features},
            atr_pips => $tick->{atr} / $opt{pip_size}, volume => $bar->{volume},
            volume_ema9 => $tick->{volume_ema9}, target => { map { $_ => 0 } (3,5,10,15) },
        };
    }

    # Se escribe en append sólo cuando su Y15 está completamente observado.
    while (@pending && $now > $pending[0]{event_time} + 15 * 60) {
        _write_row($out, shift @pending, \%opt);
        ++$rows;
    }
}

# EOF: los pendientes no tienen los 15m futuros completos; se descartan para
# no convertir futuro desconocido en ceros falsos.
my $discarded = scalar @pending;
close $in;
close $out or die "No se pudo cerrar $opt{output}: $!\n";
printf "Headless terminado: eventos=%d filas=%d descartadas_Y_incompleto=%d\n", $events, $rows, $discarded;

sub _columns_out {
    my @c = qw(event_date_utc event_time_utc event_minute_utc event_id ghost_type ghost_pivot_price confirmation_index price_hlc3);
    for my $tf (qw(1m 10m 1h)) {
        for my $kind (qw(order_block fvg fibonacci anchored_vwap volume_profile htf_sr bos_choch eqh_eql sweep_grab_run supply_demand channels_trendlines)) {
            push @c, map { "${tf}_${kind}_${_}" } qw(dist_level_pips dist_range_low_pips dist_range_high_pips available);
        }
    }
    return [ @c, qw(atr_14_pips volume volume_ema_9 target_rastro_next_3m target_rastro_next_5m target_rastro_next_10m target_rastro_next_15m) ];
}

sub _columns {
    my ($line) = @_; chomp $line; $line =~ s/\r$//;
    my @h = map { lc _trim($_) } split /,/, $line, -1;
    my %c; $c{$h[$_]} = $_ for 0 .. $#h; return %c;
}
sub _parse_bar {
    my ($line, $col, $line_no) = @_;
    chomp $line; $line =~ s/\r$//;
    my @v = split /,/, $line, -1; # el CSV entregado no contiene campos textuales con comas
    my %b;
    $b{time} = Market::ML::RawCsv::parse_iso8601_epoch(_trim($v[$col->{time}]));
    die "Timestamp inválido en línea $line_no\n" unless defined $b{time};
    for my $name (qw(open high low close volume)) {
        my $value = _trim($v[$col->{$name}]);
        die "$name inválido en línea $line_no\n" unless defined($value) && $value =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)$/;
        $b{$name} = $value + 0;
    }
    die "OHLC inválido en línea $line_no\n" if $b{high} < $b{low} || $b{open} < $b{low} || $b{open} > $b{high} || $b{close} < $b{low} || $b{close} > $b{high} || $b{volume} < 0;
    return \%b;
}
sub _write_row {
    my ($fh, $row, $opt) = @_;
    my ($date, $time, $minute) = (strftime('%Y-%m-%d', gmtime($row->{event_time})), strftime('%H:%M:%S', gmtime($row->{event_time})), strftime('%M', gmtime($row->{event_time})));
    my @out = ($date, $time, $minute, $row->{event}{id}, $row->{event}{type}, $row->{event}{price}, $row->{index}, $row->{price});
    for my $tf (qw(1m 10m 1h)) { push @out, _distances($row->{features}{$tf}, $row->{price}, $opt->{pip_size}); }
    push @out, map { _num($_) } ($row->{atr_pips}, $row->{volume}, $row->{volume_ema9}, @{$row->{target}}{3,5,10,15});
    print {$fh} _csv_line(\@out);
}
sub _distances {
    my ($levels, $price, $pip) = @_; my @out;
    for my $kind (qw(order_block fvg fibonacci anchored_vwap volume_profile htf_sr bos_choch eqh_eql sweep_grab_run supply_demand channels_trendlines)) {
        my $x = _nearest($levels->{$kind}, $price);
        if (!$x) {
            push @out, (0, 0, 0, 0);
        } else {
            push @out, map { _num(($_ - $price) / $pip) } ($x->{level}, $x->{low}, $x->{high});
            push @out, 1;
        }
    }
    return @out;
}
sub _nearest {
    my ($items, $price) = @_;
    return undef unless $items && @$items;
    my $best;
    for my $item (@$items) {
        next unless ref($item) eq 'HASH' && defined $item->{level};
        $best = $item if !$best || abs($item->{level} - $price) < abs($best->{level} - $price);
    }
    return $best;
}
sub _hlc3 { return ($_[0]{high}+$_[0]{low}+$_[0]{close})/3 }
sub _num { return sprintf('%.10g', $_[0] // 0) }
sub _trim { my $x=defined($_[0])?$_[0]:''; $x =~ s/^\s+|\s+$//g; return $x }
sub _csv_line { my ($a)=@_; return join(',', map { my $v=defined($_)?$_:''; $v =~ s/"/""/g; qq{"$v"} } @$a)."\n" }

package HeadlessLevelEngine;
sub new {
    my ($class,%o)=@_; my $self=bless { i=>-1, pip=>$o{pip_size}, ghost=>GhostStream->new(length=>$o{pivot_length}),
        f1=>FeatureFrame->new(name=>'1m', profile_bars=>$o{profile_bars}), f10=>FeatureFrame->new(name=>'10m', profile_bars=>$o{profile_bars}), f60=>FeatureFrame->new(name=>'1h', profile_bars=>$o{profile_bars}),
        a10=>Bucket->new(600), a60=>Bucket->new(3600), a240=>Bucket->new(14400), ad=>Bucket->new(86400), aw=>Bucket->new(604800), htf=>[], atr=>undef, prev_close=>undef, ema=>undef },$class; return $self;
}
sub feed {
    my ($s,$bar)=@_; ++$s->{i};
    my $tr=!defined($s->{prev_close}) ? $bar->{high}-$bar->{low} : _max($bar->{high}-$bar->{low},abs($bar->{high}-$s->{prev_close}),abs($bar->{low}-$s->{prev_close}));
    $s->{atr}=defined($s->{atr}) ? ($s->{atr}*13+$tr)/14 : $tr; $s->{prev_close}=$bar->{close}; $s->{ema}=defined($s->{ema}) ? .2*$bar->{volume}+.8*$s->{ema}:$bar->{volume};
    $s->{f1}->feed($bar,$s->{i});
    for my $pair ([a10=>'f10'],[a60=>'f60']) { my $done=$s->{$pair->[0]}->feed($bar); $s->{$pair->[1]}->feed($done,$s->{i}) if $done; }
    for my $bucket ($s->{a240},$s->{ad},$s->{aw}) { my $done=$bucket->feed($bar); push @{$s->{htf}},$done if $done; }
    splice @{$s->{htf}},0,@{$s->{htf}}-12 if @{$s->{htf}}>12;
    my $g=$s->{ghost}->feed($bar,$s->{i});
    my @htf;
    for my $bar (@{ $s->{htf} }) {
        push @htf,
            { level => $bar->{high}, low => $bar->{high}, high => $bar->{high} },
            { level => $bar->{low},  low => $bar->{low},  high => $bar->{low}  };
    }
    my $htf = \@htf;
    my $tick = { index=>$s->{i}, ghosts=>$g->{ghosts}, trace_one=>$g->{trace_one}, atr=>$s->{atr}, volume_ema9=>$s->{ema} };
    # VP y los once grupos se materializan sólo al pausar por un fantasma;
    # calcularlos en cada una de las 88k velas derrotaría el streaming.
    $tick->{features} = { '1m'=>$s->{f1}->levels($htf), '10m'=>$s->{f10}->levels($htf), '1h'=>$s->{f60}->levels($htf) }
        if @{ $g->{ghosts} };
    return $tick;
}
sub _max { my $m=shift; for(@_){$m=$_ if $_>$m} return $m }

package Bucket;
sub new { bless { sec=>$_[1], cur=>undef },$_[0] }
sub feed {
    my ($s, $c) = @_;
    my $bucket = int($c->{time} / $s->{sec}) * $s->{sec};
    # Si aparece un hueco, cerrar el bucket anterior antes de abrir el nuevo.
    if ($s->{cur} && $s->{cur}{time} != $bucket) {
        my $done = $s->{cur};
        $s->{cur} = { %$c, time => $bucket };
        return $done;
    }
    if (!$s->{cur}) {
        $s->{cur} = { %$c, time => $bucket };
    } else {
        $s->{cur}{high} = $c->{high} if $c->{high} > $s->{cur}{high};
        $s->{cur}{low}  = $c->{low}  if $c->{low}  < $s->{cur}{low};
        $s->{cur}{close} = $c->{close};
        $s->{cur}{volume} += $c->{volume};
    }
    # La barra de entrada es 1m: al llegar exactamente al borde, el HTF ya
    # está cerrado y puede formar parte de la foto de este mismo minuto.
    if ($c->{time} + 60 == $bucket + $s->{sec}) {
        my $done = $s->{cur};
        $s->{cur} = undef;
        return $done;
    }
    return undef;
}

package FeatureFrame;
sub new { my($c,%o)=@_;bless {bars=>[],pivots=>[],last_ob=>undef,last_fvg=>undef,last_eq=>undef,last_sweep=>undef,last_zone=>undef,vwap=>undef,w=>0,m2=>0,profile=>$o{profile_bars}//500},$c }
sub feed {
 my($s,$c,$global)=@_; push @{$s->{bars}},{%$c,index=>$global}; splice @{$s->{bars}},0,@{$s->{bars}}-$s->{profile} if @{$s->{bars}}>$s->{profile};
 my $p=($c->{high}+$c->{low}+$c->{close})/3; my $nw=$s->{w}+$c->{volume}; if($nw>0){my $d=$p-($s->{vwap}//0);my $nm=($s->{vwap}//0)+$c->{volume}/$nw*$d;$s->{m2}+=$c->{volume}*$d*($p-$nm);$s->{vwap}=$nm;$s->{w}=$nw;}
 my $b=$s->{bars}; if(@$b>=3){my($a,$m,$z)=@$b[-3..-1]; if($z->{low}>$a->{high}){$s->{last_fvg}={level=>($z->{low}+$a->{high})/2,low=>$a->{high},high=>$z->{low}}} if($z->{high}<$a->{low}){$s->{last_fvg}={level=>($z->{high}+$a->{low})/2,low=>$z->{high},high=>$a->{low}}}}
 if(@$b>=7){my $x=$b->[-4];my($hi,$lo)=(1,1);for my$k(@$b[-7..-1]){next if$k==$x;$hi=0 if$k->{high}>=$x->{high};$lo=0 if$k->{low}<=$x->{low}} if($hi||$lo){my$q={type=>$hi?'high':'low',price=>$hi?$x->{high}:$x->{low},index=>$x->{index}};push@{$s->{pivots}},$q;splice@{$s->{pivots}},0,@{$s->{pivots}}-12 if@{$s->{pivots}}>12;}}
 my$last=$s->{pivots}[-1]; if($last){if($last->{type}eq'high'&&$c->{high}>$last->{price}){$s->{last_ob}=_opposite($b,'bear');$s->{last_sweep}={level=>$last->{price},low=>$last->{price},high=>$last->{price}} if$c->{close}<$last->{price}}if($last->{type}eq'low'&&$c->{low}<$last->{price}){$s->{last_ob}=_opposite($b,'bull');$s->{last_sweep}={level=>$last->{price},low=>$last->{price},high=>$last->{price}} if$c->{close}>$last->{price}}}
 $s->{last_zone}= $c->{close}>$c->{open}?{level=>$c->{low},low=>$c->{low},high=>$c->{open}}:{level=>$c->{high},low=>$c->{open},high=>$c->{high}};
}
sub levels {
 my($s,$htf)=@_;my$p=$s->{pivots};my($fib,$channel,$bos,$eq); if(@$p>=2){my($a,$b)=@$p[-2,-1];$fib={level=>($a->{price}+$b->{price})/2,low=>($a->{price}<$b->{price}?$a->{price}:$b->{price}),high=>($a->{price}>$b->{price}?$a->{price}:$b->{price})};$bos={level=>$b->{price},low=>$b->{price},high=>$b->{price}};if($a->{type}eq$b->{type}){$channel={level=>$b->{price},low=>$b->{price},high=>$b->{price}};if(abs($a->{price}-$b->{price})<=abs($b->{price})*.0005){$eq=$channel}}}my$vp=_vp($s->{bars});my$sd=$s->{w}>0?sqrt($s->{m2}/$s->{w}):0;my$v=$s->{vwap};return {order_block=>[$s->{last_ob}?$s->{last_ob}:()],fvg=>[$s->{last_fvg}?$s->{last_fvg}:()],fibonacci=>[$fib?$fib:()],anchored_vwap=>[defined$v?{level=>$v,low=>$v-$sd,high=>$v+$sd}:()],volume_profile=>[$vp?$vp:()],htf_sr=>$htf,bos_choch=>[$bos?$bos:()],eqh_eql=>[$eq?$eq:()],sweep_grab_run=>[$s->{last_sweep}?$s->{last_sweep}:()],supply_demand=>[$s->{last_zone}?$s->{last_zone}:()],channels_trendlines=>[$channel?$channel:()]}; }
sub _opposite { my($b,$side)=@_;for(reverse@$b){next if$side eq'bear'&&$_->{close}>= $_->{open};next if$side eq'bull'&&$_->{close}<= $_->{open};return{level=>($_->{high}+$_->{low})/2,low=>$_->{low},high=>$_->{high}}}return undef }
sub _vp { my($b)=@_;return undef unless@$b;my($lo,$hi)=($b->[0]{low},$b->[0]{high});for(@$b){$lo=$_->{low} if $_->{low}<$lo;$hi=$_->{high} if $_->{high}>$hi}return{level=>$lo,low=>$lo,high=>$hi}if$hi==$lo;my$n=32;my@v=(0)x$n;for(@$b){my$i=int((($_->{high}+$_->{low}+$_->{close})/3-$lo)/($hi-$lo)*$n);$i=0 if $i<0;$i=$n-1 if $i>=$n;$v[$i]+=$_->{volume}}my$pi=0;for(1..$#v){$pi=$_ if $v[$_]>$v[$pi]}my$sum=0;$sum+=$_ for@v;my($l,$h,$got)=($pi,$pi,$v[$pi]);while($got<$sum*.7&&($l>0||$h<$#v)){if($l>0){$got+=$v[--$l]}if($got>=$sum*.7){last}if($h<$#v){$got+=$v[++$h]}}my$step=($hi-$lo)/$n;return{level=>$lo+($pi+.5)*$step,low=>$lo+$l*$step,high=>$lo+($h+1)*$step} }

package GhostStream;
sub new {my($c,%o)=@_;bless{n=>$o{length},bars=>[],last=>undef,track_max=>undef,track_min=>undef,follow_max=>undef,follow_min=>undef},$c}
sub feed {
 my($s,$c,$i)=@_;push@{$s->{bars}},{%$c,index=>$i};my$n=$s->{n};splice@{$s->{bars}},0,@{$s->{bars}}-(2*$n+1)if@{$s->{bars}}>2*$n+1;my@ghost;return{ghosts=>\@ghost,trace_one=>0}if@{$s->{bars}}<2*$n+1;my$x=$s->{bars}[$n];$s->{track_max}=$x if!$s->{track_max}||$x->{high}>$s->{track_max}{high};$s->{track_min}=$x if!$s->{track_min}||$x->{low}<$s->{track_min}{low};$s->{follow_max}=$x if!$s->{follow_max}||$x->{high}>$s->{follow_max}{high};$s->{follow_min}=$x if!$s->{follow_min}||$x->{low}<$s->{follow_min}{low};my($ph,$pl)=(1,1);for my$b(@{$s->{bars}}){next if$b==$x;$ph=0if$b->{high}>=$x->{high};$pl=0if$b->{low}<=$x->{low}}if($ph||$pl){my$type=$ph?'high':'low';if($s->{last}){if($s->{last}{type}eq$type){my$z=$type eq'high'?$s->{track_min}:$s->{track_max};push@ghost,_g($z,$type eq'high'?'low':'high',$i)}elsif(($type eq'high'&&$x->{high}<$s->{track_max}{high})||($type eq'low'&&$x->{low}>$s->{track_min}{low})){my$a=$type eq'high'?$s->{track_max}:$s->{track_min};my$b=$type eq'high'?$s->{follow_min}:$s->{follow_max};push@ghost,_g($a,$type,$i),_g($b,$type eq'high'?'low':'high',$i)}}$s->{last}={type=>$type,%$x};$s->{track_max}=$s->{track_min}=$s->{follow_max}=$s->{follow_min}=$x}return{ghosts=>\@ghost,trace_one=>($s->{last}&&$s->{last}{index}<$i)?1:0} }
sub _g {my($x,$type,$i)=@_;return{id=>join('_','ghost',$type,$x->{index},$i),type=>$type,price=>$type eq'high'?$x->{high}:$x->{low}} }

1;
