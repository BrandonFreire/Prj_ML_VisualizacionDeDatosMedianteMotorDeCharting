#!/usr/bin/perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin;
use POSIX qw(strftime);

my $HAS_MOMENT;
BEGIN {
    eval { require Time::Moment; $HAS_MOMENT = 1 };
}

use Market::MarketData;

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

my $csv_file = $ARGV[0] // '2026_03.csv';
my $market   = Market::MarketData->new();

open my $fh, '<', $csv_file or die "Cannot open $csv_file: $!";
<$fh>;
while ( my $line = <$fh> ) {
    chomp $line;
    my ($time_str, $open, $high, $low, $close, $volume) = split /,/, $line;
    next unless defined $volume;

    $market->add_candle({
        time   => parse_ts($time_str),
        open   => $open   + 0,
        high   => $high   + 0,
        low    => $low    + 0,
        close  => $close  + 0,
        volume => $volume + 0,
    });
}
close $fh;

$market->build_timeframes();

for my $tf ( '1', '5', '15' ) {
    $market->set_timeframe($tf);
    print_timeframe_samples($market, $tf);
}

sub print_timeframe_samples {
    my ($market, $tf) = @_;
    my $n = $market->size();
    print "\n=== ${tf}m candles: $n ===\n";
    print_section($market, 'first 10', 0, 9);

    my $mid_start = int($n / 2) - 5;
    $mid_start = 0 if $mid_start < 0;
    print_section($market, 'middle 10', $mid_start, $mid_start + 9);

    my $last_start = $n - 10;
    $last_start = 0 if $last_start < 0;
    print_section($market, 'last 10', $last_start, $n - 1);
}

sub print_section {
    my ($market, $title, $start, $end) = @_;
    my $n = $market->size();
    $end = $n - 1 if $end >= $n;
    return if $start > $end;

    print "\n-- $title --\n";
    print "index  time              open      high      low       close     volume\n";
    for my $i ($start .. $end) {
        my $c = $market->get_candle($i);
        next unless $c;
        my $time = strftime( "%Y-%m-%d %H:%M", localtime( $c->{time} ) );
        printf "%5d  %s  %8.2f  %8.2f  %8.2f  %8.2f  %.0f\n",
            $i, $time, $c->{open}, $c->{high}, $c->{low}, $c->{close}, $c->{volume};
    }
}
