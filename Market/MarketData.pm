package Market::MarketData;

use strict;
use warnings;
use POSIX qw(floor);
use AI::MXNet qw(mx);

sub new {
    my ($class) = @_;
    my $self = {
        data       => { '1' => [], '5' => [], '15' => [] },
        current_tf => '1',
        _cursor    => undef,
    };
    bless $self, $class;
    return $self;
}

sub get_data {
    my ($self) = @_;
    return $self->{data};
}

sub add_candle {
    my ($self, $candle) = @_;
    push @{ $self->{data}{'1'} }, $candle;
}

# Build higher-timeframe candles from 1m data using integer arithmetic for bucket boundaries.
# (MXNet float32 pierde precision con epochs de 2026: ULP ~128seg, bucket 5m=300seg → error de asignacion)
sub build_tf_candles {
    my ($self, $tf) = @_;
    my @base    = @{ $self->{data}{'1'} };
    my $n       = scalar @base;
    my $tf_secs = $tf * 60;
    return unless $n > 0;

    # ---- Extract columns ----
    my (@times, @opens, @highs, @lows, @closes, @vols);
    for my $c (@base) {
        push @times,  $c->{time};
        push @opens,  $c->{open};
        push @highs,  $c->{high};
        push @lows,   $c->{low};
        push @closes, $c->{close};
        push @vols,   $c->{volume};
    }

    # ---- Bucket timestamps (enteros Perl: float32 de MXNet pierde precision en epochs 2026) ----
    # float32 ULP para ~1.78e9 es 128 seg → velas al borde del bucket caen en el bucket equivocado.
    my @buckets = map { int($times[$_] / $tf_secs) * $tf_secs } 0 .. $n - 1;

    # ---- Group boundary detection (Perl integers) ----
    my @starts = (0);
    for my $i (0 .. $n - 2) {
        push @starts, $i + 1 if $buckets[$i + 1] != $buckets[$i];
    }

    # ---- Per-group aggregation (Perl loop over groups, Perl arrays for speed) ----
    # MXNet overhead per call is too high for 6000 tiny slices.
    # Tensor work is done above (bucket computation + boundary detection on 30k elements).
    my @result;
    for my $gi (0 .. $#starts) {
        my $s  = $starts[$gi];
        my $e  = ($gi + 1 < scalar @starts) ? $starts[$gi + 1] - 1 : $n - 1;

        my $high = $highs[$s];
        my $low  = $lows[$s];
        my $vol  = $vols[$s];

        for my $i ($s + 1 .. $e) {
            $high = $highs[$i] if $highs[$i] > $high;
            $low  = $lows[$i]  if $lows[$i]  < $low;
            $vol += $vols[$i];
        }

        push @result, {
            time   => $buckets[$s],
            open   => $opens[$s],
            high   => $high,
            low    => $low,
            close  => $closes[$e],
            volume => $vol,
        };
    }

    $self->{data}{$tf} = \@result;
}

sub build_timeframes {
    my ($self) = @_;
    $self->build_tf_candles(5);
    $self->build_tf_candles(15);
}

sub set_timeframe {
    my ($self, $tf) = @_;
    $self->{current_tf} = $tf;
}

sub _active_array {
    my ($self) = @_;
    return $self->{data}{ $self->{current_tf} };
}

sub get_slice {
    my ($self, $start, $end) = @_;
    my $arr  = $self->_active_array();
    my $size = scalar @$arr;
    $start = 0          if $start < 0;
    $end   = $size - 1  if $end >= $size;
    return [] if $start > $end;
    return [ @{$arr}[ $start .. $end ] ];
}

sub get_candle {
    my ($self, $index) = @_;
    return $self->_active_array()->[$index];
}

sub size {
    my ($self) = @_;
    return scalar @{ $self->_active_array() };
}

sub last_candle {
    my ($self) = @_;
    my $arr = $self->_active_array();
    return defined $self->{_cursor} ? $arr->[ $self->{_cursor} ] : $arr->[-1];
}

sub last_index {
    my ($self) = @_;
    return defined $self->{_cursor} ? $self->{_cursor} : $self->size() - 1;
}

sub get_timestamp {
    my ($self, $index) = @_;
    my $c = $self->get_candle($index);
    return $c ? $c->{time} : undef;
}

sub merge_delta_row {
    my ($self, $row) = @_;
    my $arr = $self->_active_array();
    if ( @$arr && $arr->[-1]{time} == $row->{time} ) {
        my $last = $arr->[-1];
        $last->{high}   = $row->{high}   if $row->{high}  > $last->{high};
        $last->{low}    = $row->{low}    if $row->{low}   < $last->{low};
        $last->{close}  = $row->{close};
        $last->{volume} += $row->{volume};
    }
    else {
        push @$arr, $row;
    }
}

sub compute_time_anchors {
    my ($self) = @_;
    my $arr      = $self->_active_array();
    my @anchors;
    my $prev_day  = -1;
    my $prev_hour = -1;

    for my $i ( 0 .. $#$arr ) {
        my @lt   = localtime( $arr->[$i]{time} );
        my $hour = $lt[2];
        my $day  = $lt[3];
        if ( $day != $prev_day ) {
            push @anchors, { index => $i, type => 'day' };
            $prev_day  = $day;
            $prev_hour = $hour;
        }
        elsif ( $hour != $prev_hour ) {
            push @anchors, { index => $i, type => 'hour' };
            $prev_hour = $hour;
        }
    }
    return \@anchors;
}

1;
