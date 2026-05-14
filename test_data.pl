#!/usr/bin/perl
# Tests data loading, timeframes and ATR - no Tk or Time::Moment required
use strict;
use warnings;
use lib '.';
use Market::MarketData;
use Market::IndicatorManager;
use Market::Indicators::ATR;

# Pure-Perl ISO-8601 to epoch (fallback for when Time::Moment isn't installed)
sub iso_to_epoch {
    my ($ts) = @_;
    return 0 unless $ts =~
        /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})([-+])(\d{2}):(\d{2})$/;
    my ($y,$mo,$d,$h,$mi,$s,$sign,$tzh,$tzm) = ($1,$2,$3,$4,$5,$6,$7,$8,$9);
    my @dim = (0,31,59,90,120,151,181,212,243,273,304,334);
    my $leap = ($y%4==0 && ($y%100!=0 || $y%400==0)) ? 1 : 0;
    my $doy  = $dim[$mo-1] + ($mo > 2 ? $leap : 0) + $d;
    my $days = ($y-1970)*365 + int(($y-1969)/4)
               - int(($y-1901)/100) + int(($y-1601)/400) + $doy - 1;
    my $utc  = $days*86400 + $h*3600 + $mi*60 + $s;
    my $off  = ($tzh*3600 + $tzm*60) * ($sign eq '+' ? 1 : -1);
    return $utc - $off;
}

my $market = Market::MarketData->new();

open my $fh, '<', '2026_03.csv' or die $!;
<$fh>;
while (<$fh>) {
    chomp;
    my ($ts, $o, $h, $l, $c, $v) = split /,/;
    next unless defined $v;
    $market->add_candle({
        time => iso_to_epoch($ts),
        open => $o+0, high => $h+0, low => $l+0, close => $c+0, volume => $v+0,
    });
}
close $fh;

$market->build_timeframes();
my $d = $market->get_data();
printf "1m=%d  5m=%d  15m=%d candles\n",
    scalar @{$d->{1}}, scalar @{$d->{5}}, scalar @{$d->{15}};

# Compute ATR(14) for 1m
my $ind = Market::IndicatorManager->new();
$ind->register('ATR', Market::Indicators::ATR->new(14));

for my $i (0..$market->last_index()) {
    $market->{_cursor} = $i;
    $ind->update_last($market);
}
delete $market->{_cursor};

my $atr = $ind->get('ATR')->get_values();
printf "ATR(14) 1m: count=%d  first=%.4f  last=%.4f\n",
    scalar @$atr, $atr->[0], $atr->[-1];

# Switch to 5m and recompute
$market->set_timeframe(5);
$ind->reset_all();
for my $i (0..$market->last_index()) {
    $market->{_cursor} = $i;
    $ind->update_last($market);
}
delete $market->{_cursor};
$atr = $ind->get('ATR')->get_values();
printf "ATR(14) 5m: count=%d  last=%.4f\n", scalar @$atr, $atr->[-1];

# Test Scales coordinate math
use Market::Panels::Scales;
my $sc = Market::Panels::Scales->new(
    x_width => 800, visible_bars => 100, start_index => 0,
    y_height => 400, y_min => 24000, y_max => 24200,
);
my $y = $sc->value_to_y(24100);
printf "value_to_y(24100) = %.1f  (expect 200.0)\n", $y;
my $v = $sc->y_to_value(200);
printf "y_to_value(200)   = %.2f  (expect 24100.00)\n", $v;
printf "index_to_x(50)    = %.1f  (expect 404.0)\n", $sc->index_to_x(50);

print "\nALL TESTS PASSED\n";
