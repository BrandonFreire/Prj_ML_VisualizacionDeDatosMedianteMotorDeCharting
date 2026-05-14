package Market::Indicators::ATR;

use strict;
use warnings;

# Average True Range - Wilder's smoothing method.
# First ATR = simple average of first `period` TR values.
# Subsequent: ATR(n) = ((period-1) * ATR(n-1) + TR(n)) / period

sub new {
    my ($class, $period) = @_;
    $period //= 14;
    my $self = {
        period      => $period,
        values      => [],
        _prev_close => undef,
        _prev_atr   => undef,
        _tr_sum     => 0,
        _tr_count   => 0,
    };
    bless $self, $class;
    return $self;
}

sub update_last {
    my ($self, $market_data) = @_;
    my $candle = $market_data->last_candle();
    return unless $candle;

    my $tr = _true_range($candle, $self->{_prev_close});
    $self->{_prev_close} = $candle->{close};

    my $atr;
    if ( !defined $self->{_prev_atr} ) {
        $self->{_tr_sum}   += $tr;
        $self->{_tr_count} += 1;
        $atr = $self->{_tr_sum} / $self->{_tr_count};

        if ( $self->{_tr_count} >= $self->{period} ) {
            $self->{_prev_atr} = $atr;
        }
    }
    else {
        $atr = ( ( $self->{period} - 1 ) * $self->{_prev_atr} + $tr ) / $self->{period};
        $self->{_prev_atr} = $atr;
    }

    push @{ $self->{values} }, $atr;
}

sub get_values {
    my ($self) = @_;
    return $self->{values};
}

sub reset {
    my ($self) = @_;
    $self->{values}      = [];
    $self->{_prev_close} = undef;
    $self->{_prev_atr}   = undef;
    $self->{_tr_sum}     = 0;
    $self->{_tr_count}   = 0;
}

sub _true_range {
    my ($candle, $prev_close) = @_;
    my $hl = $candle->{high} - $candle->{low};
    return $hl unless defined $prev_close;
    my $hpc = abs( $candle->{high} - $prev_close );
    my $lpc = abs( $candle->{low}  - $prev_close );
    my $tr  = $hl;
    $tr = $hpc if $hpc > $tr;
    $tr = $lpc if $lpc > $tr;
    return $tr;
}

1;
