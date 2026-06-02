#!/usr/bin/perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib $Bin;
use POSIX qw(strftime);

use Market::MarketData;

my $csv_file = $ARGV[0] // '2026_03.csv';
my $market   = Market::MarketData->new();

open my $fh, '<', $csv_file or die "Cannot open $csv_file: $!";
<$fh>;
while ( my $line = <$fh> ) {
    chomp $line;
    my ($time_str, $open, $high, $low, $close, $volume) = split /,/, $line;
    next unless defined $volume;
    my $epoch = Market::MarketData->parse_timestamp($time_str);
    die "Invalid timestamp in $csv_file: $time_str\n" unless defined $epoch;

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

$market->build_timeframes();
validate_timeframes($market);

for my $tf ( '1', '5', '15' ) {
    $market->set_timeframe($tf);
    print_timeframe_samples($market, $tf);
}

sub validate_timeframes {
    my ($market) = @_;
    validate_array($market->get_data()->{'1'}, 1);
    validate_array($market->get_data()->{'5'}, 5);
    validate_array($market->get_data()->{'15'}, 15);
    validate_aggregate($market, 5);
    validate_aggregate($market, 15);
    print "Validation OK: 1m sorted, 5m/15m aligned, OHLCV aggregation matches base candles.\n";
}

sub validate_array {
    my ($arr, $tf) = @_;
    my $tf_secs = $tf * 60;
    for my $i (0 .. $#$arr) {
        my $c = $arr->[$i];
        die "${tf}m candle $i has invalid high/low\n"
            if $c->{high} < $c->{low};
        die "${tf}m candle $i open outside high/low\n"
            if $c->{open} > $c->{high} || $c->{open} < $c->{low};
        die "${tf}m candle $i close outside high/low\n"
            if $c->{close} > $c->{high} || $c->{close} < $c->{low};
        die "${tf}m candle $i timestamp is not aligned\n"
            if $tf > 1 && $c->{time} % $tf_secs != 0;
        die "${tf}m candles are not sorted at $i\n"
            if $i > 0 && $arr->[$i - 1]{time} > $c->{time};
    }
}

sub validate_aggregate {
    my ($market, $tf) = @_;
    my $base = $market->get_data()->{'1'};
    my $got  = $market->get_data()->{$tf};
    my $tf_secs = $tf * 60;
    my @expected;
    my $cur;
    my $bucket;

    for my $c (@$base) {
        my $b = int($c->{time} / $tf_secs) * $tf_secs;
        if (!defined $bucket || $b != $bucket) {
            push @expected, $cur if $cur;
            $bucket = $b;
            $cur = {
                time   => $b,
                open   => $c->{open},
                high   => $c->{high},
                low    => $c->{low},
                close  => $c->{close},
                volume => $c->{volume},
            };
            next;
        }
        $cur->{high} = $c->{high} if $c->{high} > $cur->{high};
        $cur->{low}  = $c->{low}  if $c->{low}  < $cur->{low};
        $cur->{close} = $c->{close};
        $cur->{volume} += $c->{volume};
    }
    push @expected, $cur if $cur;

    die "${tf}m candle count mismatch: got " . scalar(@$got) . " expected " . scalar(@expected) . "\n"
        if scalar(@$got) != scalar(@expected);

    for my $i (0 .. $#expected) {
        for my $field (qw(time open high low close volume)) {
            die "${tf}m mismatch at candle $i field $field: got $got->[$i]{$field} expected $expected[$i]{$field}\n"
                if $got->[$i]{$field} != $expected[$i]{$field};
        }
    }
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
