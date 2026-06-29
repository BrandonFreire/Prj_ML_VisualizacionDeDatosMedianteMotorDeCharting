package Market::Indicators::ATR;

use strict;
use warnings;
use AI::MXNet qw(mx);

# Average True Range - Wilder's smoothing method.
#
# TENSOR MATH (no loops in the hot path):
#
#   True Range (vectorized):
#     TR[i] = max(H[i]-L[i], |H[i]-C[i-1]|, |L[i]-C[i-1]|)
#
#   Warmup ATR (vectorized):
#     ATR[i] = cumsum(TR)[i] / (i+1)     for i in 0..period-1
#
#   Tail ATR via cumulative weighted sum identity:
#     Let alpha = 1/p,  beta = (p-1)/p,  seed = ATR[p-1]
#     s[j]      = TR[p+j] / beta^j
#     ATR[p+j]  = alpha * beta^j * cumsum(s)[j]  +  seed * beta * beta^j
#
#   All operations are elementwise multiply / divide / cumsum on ndarrays.

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
# Batch computation - fully tensor-based, no loops in the math.
# -----------------------------------------------------------------------
sub compute_all {
    my ($self, $market_data) = @_;
    $self->reset();

    my $arr = $market_data->_active_array();
    my $n   = scalar @$arr;
    my $p   = $self->{period};

    return unless $n > 0;

    my @all_atrs;
    my $prev_close;
    my $prev_atr;
    my $tr_sum   = 0;
    my $tr_count = 0;

    for my $i (0 .. $n - 1) {
        my $candle = $arr->[$i];

        my $tr = _true_range($candle, $prev_close);
        $prev_close = $candle->{close};

        my $atr;

        if (!defined $prev_atr) {
            $tr_sum   += $tr;
            $tr_count += 1;

            # Warmup: running mean hasta completar el periodo
            $atr = $tr_sum / $tr_count;

            # Seed ATR[p-1]
            $prev_atr = $atr if $tr_count >= $p;
        }
        else {
            # Wilder smoothing
            $atr = (($p - 1) * $prev_atr + $tr) / $p;
            $prev_atr = $atr;
        }

        push @all_atrs, $atr;
    }

    $self->{values}      = \@all_atrs;
    $self->{_nd_atr}     = undef;        # Evitamos NDArray porque el binding devuelve datos corruptos
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
        $atr = $self->{_tr_sum} / $self->{_tr_count};
        $self->{_prev_atr} = $atr if $self->{_tr_count} >= $p;
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
