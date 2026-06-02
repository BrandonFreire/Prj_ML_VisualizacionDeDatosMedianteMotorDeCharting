package Market::MarketData;

use strict;
use warnings;
use POSIX qw(floor);

my $HAS_MOMENT;
BEGIN {
    eval { require Time::Moment; $HAS_MOMENT = 1 };
}

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

# Parse ISO timestamps with explicit timezone offsets.
sub parse_timestamp {
    my ($class_or_self, $ts) = @_;
    if ($HAS_MOMENT) {
        return Time::Moment->from_string($ts)->epoch;
    }

    return undef unless defined $ts && $ts =~
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

# Build higher-timeframe candles with integer timestamp buckets.
# Do not use float tensors for epochs: float32 loses minute-level precision.
sub build_tf_candles {
    my ($self, $tf) = @_;
    my @base    = @{ $self->{data}{'1'} };
    my $n       = scalar @base;
    my $tf_secs = $tf * 60;
    return unless $n > 0;
    if ( $tf == 1 ) {
        $self->{data}{'1'} = \@base;
        return;
    }

    my @result;
    my $current;
    my $current_bucket;

    for my $c (@base) {
        my $bucket = int( $c->{time} / $tf_secs ) * $tf_secs;

        if ( !defined $current_bucket || $bucket != $current_bucket ) {
            push @result, $current if $current;
            $current_bucket = $bucket;
            $current = {
                time   => $bucket,
                open   => $c->{open},
                high   => $c->{high},
                low    => $c->{low},
                close  => $c->{close},
                volume => $c->{volume},
            };
            next;
        }

        $current->{high}   = $c->{high} if $c->{high} > $current->{high};
        $current->{low}    = $c->{low}  if $c->{low}  < $current->{low};
        $current->{close}  = $c->{close};
        $current->{volume} += $c->{volume};
    }
    push @result, $current if $current;

    $self->{data}{$tf} = \@result;
}

sub build_timeframes {
    my ($self) = @_;
    @{ $self->{data}{'1'} } = sort { $a->{time} <=> $b->{time} } @{ $self->{data}{'1'} };
    $self->build_tf_candles(5);
    $self->build_tf_candles(15);
}

sub set_timeframe {
    my ($self, $tf) = @_;
    die "Unsupported timeframe: $tf" unless exists $self->{data}{$tf};
    $self->{current_tf} = $tf;
}

sub _active_array {
    my ($self) = @_;
    return $self->{data}{ $self->{current_tf} } || [];
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
    my $arr = $self->_active_array();
    return undef if !defined $index || $index < 0 || $index > $#$arr;
    return $arr->[$index];
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
    return \@anchors unless @$arr;

    my %seen;
    my $prev_day_key;
    my $prev_hour = -1;

    for my $i ( 0 .. $#$arr ) {
        my @lt      = localtime( $arr->[$i]{time} );
        my $minute  = $lt[1];
        my $hour    = $lt[2];
        my $day_key = sprintf( "%04d-%02d-%02d", $lt[5] + 1900, $lt[4] + 1, $lt[3] );

        if ( !defined $prev_day_key || $day_key ne $prev_day_key ) {
            _add_anchor( \@anchors, \%seen, $i, 'day' );
            $prev_day_key = $day_key;
            $prev_hour = $hour;
        }
        elsif ( $hour != $prev_hour ) {
            _add_anchor( \@anchors, \%seen, $i, 'hour' );
            $prev_hour = $hour;
        }

        _add_anchor( \@anchors, \%seen, $i, 'midnight' )    if $hour == 0  && $minute == 0;
        _add_anchor( \@anchors, \%seen, $i, 'market_open' ) if $hour == 17 && $minute == 0;
    }

    _add_anchor( \@anchors, \%seen, $#$arr, 'last' );

    return \@anchors;
}

sub _anchor_priority {
    my ($type) = @_;
    return 0 if $type eq 'last';
    return 1 if $type eq 'midnight';
    return 2 if $type eq 'market_open';
    return 3 if $type eq 'day';
    return 4 if $type eq 'hour';
    return 5;
}

sub _add_anchor {
    my ($anchors, $seen, $index, $type) = @_;
    my $priority = _anchor_priority($type);

    if ( exists $seen->{$index} ) {
        my $pos = $seen->{$index};
        return if $anchors->[$pos]{priority} <= $priority;
        $anchors->[$pos] = {
            index    => $index,
            type     => $type,
            priority => $priority,
        };
        return;
    }

    $seen->{$index} = scalar @$anchors;
    push @$anchors, {
        index    => $index,
        type     => $type,
        priority => $priority,
    };
}

1;
