package Market::MarketData;

use strict;
use warnings;
use POSIX qw(floor);

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

sub build_tf_candles {
    my ($self, $tf) = @_;
    my @base   = @{ $self->{data}{'1'} };
    my @result;
    my $tf_secs = $tf * 60;
    my $i = 0;

    while ($i < scalar @base) {
        my $bucket = floor($base[$i]{time} / $tf_secs) * $tf_secs;
        my $open   = $base[$i]{open};
        my $high   = $base[$i]{high};
        my $low    = $base[$i]{low};
        my $close  = $base[$i]{close};
        my $vol    = $base[$i]{volume};
        $i++;

        while ($i < scalar @base) {
            my $nb = floor($base[$i]{time} / $tf_secs) * $tf_secs;
            last if $nb != $bucket;
            $high  = $base[$i]{high}   if $base[$i]{high}  > $high;
            $low   = $base[$i]{low}    if $base[$i]{low}   < $low;
            $close = $base[$i]{close};
            $vol  += $base[$i]{volume};
            $i++;
        }

        push @result, {
            time   => $bucket,
            open   => $open,
            high   => $high,
            low    => $low,
            close  => $close,
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
    $start = 0        if $start < 0;
    $end   = $size - 1 if $end >= $size;
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
        $last->{high}   = $row->{high}   if $row->{high}   > $last->{high};
        $last->{low}    = $row->{low}    if $row->{low}    < $last->{low};
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
