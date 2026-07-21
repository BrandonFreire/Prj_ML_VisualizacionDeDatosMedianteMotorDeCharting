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
        # Cada mutacion de velas invalida el cache de volumen. El cache se
        # conserva por temporalidad macro para que volver de 1h a 5m no
        # reconstruya los mismos buckets 1m/5m/15m.
        _data_revision       => 0,
        _volume_index        => {},
        _volume_index_cache  => {},
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
    $self->_touch_data();
}

# Build higher-timeframe candles from 1m data using integer arithmetic for bucket boundaries.
# Evita float32 para epochs de 2026; los buckets se calculan con enteros Perl.
sub build_tf_candles {
    my ($self, $tf, %opts) = @_;
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
    $self->_touch_data() unless $opts{defer_cache_invalidation};
}

sub build_timeframes {
    my ($self) = @_;
    for my $tf (qw(5 15 60 120 240 1440 10080)) {
        $self->build_tf_candles($tf, defer_cache_invalidation => 1);
    }
    $self->_touch_data();
}

## ----------------------------------------------------------------
# Índice de volumen multi-temporal (Sección 4.4 de la especificación)
#
# Para cada vela de la temporalidad macro activa, almacena la suma de
# volumen de las sub-velas de 1m, 5m y 15m que caen dentro de ese
# bucket temporal.  Se construye O(N) una sola vez; lookup O(1).
# ----------------------------------------------------------------
sub build_volume_index {
    my ($self, $tf_macro) = @_;
    $tf_macro //= $self->{current_tf} // '1';
    my $revision = $self->{_data_revision} // 0;
    my $cached = $self->{_volume_index_cache}{$tf_macro};
    if ($cached && ($cached->{revision} // -1) == $revision) {
        $self->{_volume_index} = $cached->{index};
        return $cached->{index};
    }

    my $tf_secs = $tf_macro * 60;

    my %index;
    for my $sub_tf (qw(1 5 15)) {
        my $sub_arr = $self->{data}{$sub_tf} // [];
        next unless @$sub_arr;
        my $key = "v${sub_tf}m";
        for my $c (@$sub_arr) {
            my $bucket = int($c->{time} / $tf_secs) * $tf_secs;
            $index{$bucket}{$key} = ($index{$bucket}{$key} // 0) + ($c->{volume} // 0);
        }
    }
    $self->{_volume_index} = \%index;
    $self->{_volume_index_cache}{$tf_macro} = {
        revision => $revision,
        index    => \%index,
    };
    return \%index;
}

sub get_volume_index { return $_[0]->{_volume_index} // {} }

sub get_volume_for_candle {
    my ($self, $candle_time) = @_;
    return undef unless defined $candle_time;
    my $vi = $self->{_volume_index} // {};
    return $vi->{$candle_time};
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
        _data_revision      => $self->{_data_revision} // 0,
        _volume_index       => {},
        _volume_index_cache => {},
    }, ref($self);
}

sub _active_array {
    my ($self) = @_;
    return $self->{data}{ $self->{current_tf} };
}

# API publica para consumidores. Mantener _active_array como detalle interno
# evita que los indicadores queden acoplados a la representacion de MarketData.
sub get_active_candles {
    my ($self) = @_;
    return $self->_active_array();
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
    $self->_touch_data();
}

sub _touch_data {
    my ($self) = @_;
    $self->{_data_revision} = ($self->{_data_revision} // 0) + 1;
    # No hace falta borrar los hashes: la revision impide reusarlos. Limpiar
    # evita que una fuente de streaming de larga duracion acumule un cache
    # obsoleto sin limite.
    $self->{_volume_index}       = {};
    $self->{_volume_index_cache} = {};
    return;
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
