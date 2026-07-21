package Market::Indicators::ATR;

use strict;
use warnings;

# Average True Range - Wilder's smoothing method.
# Pure Perl implementation kept deliberately simple and deterministic.
# Earlier MXNet ndarray paths were fragile in this project environment.

sub new {
    my ($class, $period) = @_;
    $period //= 14;
    my $self = {
        period      => $period,
        values      => [],
        _nd_atr     => undef,
        # Incremental fallback state
        _prev_close => undef,
        _prev_atr   => undef,
        _tr_sum     => 0,
        _tr_count   => 0,
    };
    bless $self, $class;
    return $self;
}

# -----------------------------------------------------------------------
# Batch computation - Wilder ATR over the active timeframe.
# -----------------------------------------------------------------------
sub compute_all {
    my ($self, $market_data) = @_;
    $self->reset();

    my $arr = $market_data->get_active_candles();
    my $n   = scalar @$arr;
    my $p   = $self->{period};
    return unless $n > 0;

    my @all_atrs;
    my $prev_close;
    my $prev_atr;
    my $tr_sum   = 0;
    my $tr_count = 0;

    for my $candle (@$arr) {
        my $tr = _true_range($candle, $prev_close);
        $prev_close = $candle->{close};

        my $atr;
        if (!defined $prev_atr) {
            $tr_sum   += $tr;
            $tr_count += 1;

            # Warmup: emit undef until Wilder's seed is available.
            if ($tr_count >= $p) {
                $atr = $tr_sum / $tr_count;
                $prev_atr = $atr;
            } else {
                $atr = undef;
            }
        }
        else {
            $atr = (($p - 1) * $prev_atr + $tr) / $p;
            $prev_atr = $atr;
        }

        push @all_atrs, $atr;
    }

    $self->{values}      = \@all_atrs;
    $self->{_nd_atr}     = undef;
    $self->{_prev_close} = $prev_close;
    $self->{_prev_atr}   = $prev_atr;
    $self->{_tr_sum}     = $tr_sum;
    $self->{_tr_count}   = $tr_count;
}

# -----------------------------------------------------------------------
# Incremental fallback (pure Perl, kept for compatibility).
# -----------------------------------------------------------------------
sub update_last {
    my ($self, $market_data) = @_;
    my $candle = $market_data->last_candle();
    return unless $candle;

    my $tr = _true_range($candle, $self->{_prev_close});
    $self->{_prev_close} = $candle->{close};

    my $p   = $self->{period};
    my $atr;
    if (!defined $self->{_prev_atr}) {
        $self->{_tr_sum}   += $tr;
        $self->{_tr_count} += 1;
        if ($self->{_tr_count} >= $p) {
            $atr = $self->{_tr_sum} / $self->{_tr_count};
            $self->{_prev_atr} = $atr;
        } else {
            $atr = undef;
        }
    }
    else {
        $atr = (($p - 1) * $self->{_prev_atr} + $tr) / $p;
        $self->{_prev_atr} = $atr;
    }
    push @{ $self->{values} }, $atr;
}

sub get_values   { $_[0]->{values}   }
sub get_ndarray  { $_[0]->{_nd_atr}  }

sub reset {
    my ($self) = @_;
    $self->{values}      = [];
    $self->{_nd_atr}     = undef;
    $self->{_prev_close} = undef;
    $self->{_prev_atr}   = undef;
    $self->{_tr_sum}     = 0;
    $self->{_tr_count}   = 0;
}

sub _true_range {
    my ($candle, $prev_close) = @_;
    my $hl = $candle->{high} - $candle->{low};
    return $hl unless defined $prev_close;
    my $hpc = abs($candle->{high} - $prev_close);
    my $lpc = abs($candle->{low}  - $prev_close);
    my $tr  = $hl;
    $tr = $hpc if $hpc > $tr;
    $tr = $lpc if $lpc > $tr;
    return $tr;
}

1;
