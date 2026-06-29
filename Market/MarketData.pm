package Market::MarketData;

use strict;
use warnings;
use POSIX qw(floor);

sub new {
    my ($class) = @_;
    my $self = {
        data       => {
            '1'     => [],
            '5'     => [],
            '15'    => [],
            '60'    => [],
            '120'   => [],
            '240'   => [],
            '1440'  => [],
            '10080' => [],
        },
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
# Evita float32 para epochs de 2026; los buckets se calculan con enteros Perl.
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

    # ---- Bucket timestamps (enteros Perl para evitar perdida de precision) ----
    # float32 ULP para ~1.78e9 es 128 seg: velas al borde caerian en el bucket equivocado.
    my @buckets = map { int($times[$_] / $tf_secs) * $tf_secs } 0 .. $n - 1;

    # ---- Group boundary detection (Perl integers) ----
    my @starts = (0);
    for my $i (0 .. $n - 2) {
        push @starts, $i + 1 if $buckets[$i + 1] != $buckets[$i];
    }

    # ---- Per-group aggregation (Perl loop over groups, Perl arrays for speed) ----
    # Evita overhead innecesario para miles de slices pequenos.
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
    for my $tf (qw(5 15 60 120 240 1440 10080)) {
        $self->build_tf_candles($tf);
    }
}

sub set_timeframe {
    my ($self, $tf) = @_;
    $self->{current_tf} = $tf;
}

sub clone_upto {
    my ($self, $last_index) = @_;
    my $tf  = $self->{current_tf};
    my $src = $self->{data}{$tf} // [];

    $last_index = $#$src unless defined $last_index;
    $last_index = $#$src if $last_index > $#$src;
    $last_index = -1    if $last_index < 0;

    my %data = map { $_ => [] } keys %{ $self->{data} };
    my @slice = $last_index >= 0 ? @{$src}[ 0 .. $last_index ] : ();
    $data{$tf} = \@slice;

    return bless {
        data       => \%data,
        current_tf => $tf,
        _cursor    => undef,
    }, ref($self);
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
