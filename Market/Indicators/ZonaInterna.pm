package Market::Indicators::ZonaInterna;

use strict;
use warnings;


sub new {
    my ($class, %args) = @_;
    my $max_x = $args{max_x} // 5;
    my $mintick = $args{mintick} // 0.25;
    die 'ZonaInterna::new: max_x must be a positive integer'
        unless defined $max_x && $max_x =~ /^\d+$/ && $max_x > 0;
    die 'ZonaInterna::new: mintick must be a positive number'
        unless _positive_number($mintick);

    return bless {
        enable618 => exists $args{enable618} ? ($args{enable618} ? 1 : 0) : 1,
        enable786 => exists $args{enable786} ? ($args{enable786} ? 1 : 0) : 1,
        max_x     => $max_x + 0,
        mintick   => $mintick + 0,
        _zigzag_ref => $args{zigzag_indicator},
        _result     => undef,
    }, $class;
}

sub set_zigzag_indicator { $_[0]->{_zigzag_ref} = $_[1]; return $_[0]; }

sub reset { $_[0]->{_result} = undef; }

sub compute_all {
    my ($self, $market) = @_;
    die 'ZonaInterna::compute_all: market data is required'
        unless $market && $market->can('get_active_candles');
    my $candles = $market->get_active_candles();
    my $zigzag = $self->{_zigzag_ref} && $self->{_zigzag_ref}->can('get_result')
        ? $self->{_zigzag_ref}->get_result() : {};
    if (!@$candles) {
        $self->{_result} = _empty('1m', -1);
        return $self->{_result};
    }
    $self->{_result} = $self->compute(
        zigzag => $zigzag, max_visible_index => $#$candles,
    );
    return $self->{_result};
}

sub update_last { return $_[0]->compute_all($_[1]); }
sub get_result { return $_[0]->{_result}; }
sub get_levels { return $_[0]->{_result}{levels} // []; }
sub get_values { return []; }

sub compute {
    my ($class_or_self, %args) = @_;
    my $self = ref($class_or_self) ? $class_or_self : $class_or_self->new(%args);
    my $max_idx = defined $args{max_visible_index} ? $args{max_visible_index} : 0;
    die 'ZonaInterna::compute: max_visible_index must be a non-negative integer'
        unless defined $max_idx && $max_idx =~ /^\d+$/;
    my $tf = $args{timeframe} // '1m';

    my @points = _zigzag_points($args{zigzag}, $max_idx);
    return _empty($tf, $max_idx) unless @points >= 3;

    my ($current, $previous, $anchor) = @points[-1, -2, -3];
    return _empty($tf, $max_idx) unless _valid_point($current) && _valid_point($previous) && _valid_point($anchor);

    my $dir = $current->{price} <=> $previous->{price};
    return _empty($tf, $max_idx) unless $dir;

    my ($ratios, $shownlevels) = $self->_ratios;
    my $diff = $anchor->{price} - $previous->{price};
    my ($stopit, @levels) = (0);
    for my $x (0 .. $#$ratios) {
        last if $stopit && $x > $shownlevels;
        my $ratio = $ratios->[$x];
        my $price = $previous->{price} + $diff * $ratio;
        my $rounded = _round_to_mintick($price, $self->{mintick});
        push @levels, {
            index         => $x,
            ratio         => $ratio,
            price         => $price,
            rounded_price => $rounded,
            text          => _fmt_ratio($ratio) . '(' . _fmt_price($rounded, $self->{mintick}) . ')',
            x1_index      => int($anchor->{index} + 0.5),
            x2_index      => $max_idx,
            direction     => $dir > 0 ? 'bullish' : 'bearish',
            color_slot    => $x % 10,
            stopit        => $stopit ? 1 : 0,
        };
        $stopit = 1 if ($dir > 0 && $price > $current->{price})
                      || ($dir < 0 && $price < $current->{price});
    }

    return {
        timeframe         => $tf,
        max_visible_index => $max_idx,
        direction         => $dir > 0 ? 'bullish' : 'bearish',
        shownlevels       => $shownlevels,
        base_price        => $previous->{price} + 0,
        diff              => $diff + 0,
        current_point     => { %$current },
        previous_point    => { %$previous },
        anchor_point      => { %$anchor },
        levels            => \@levels,
        replay_safe       => 1,
    };
}

sub _ratios {
    my ($self) = @_;
    my @ratios;
    my $shownlevels = 0;
    if ($self->{enable618}) { push @ratios, 0.618; $shownlevels++; }
    if ($self->{enable786}) { push @ratios, 0.786; $shownlevels++; }
    for my $x (1 .. $self->{max_x}) {
        push @ratios, $x, $x + 0.272, $x + 0.414, $x + 0.618;
    }
    return (\@ratios, $shownlevels);
}

sub _zigzag_points {
    my ($zigzag, $max_idx) = @_;
    return () unless defined $zigzag;
    my @raw;
    if (ref($zigzag) eq 'ARRAY') {
        @raw = @$zigzag;
    }
    elsif (ref($zigzag) eq 'HASH') {
        if (ref($zigzag->{pivots}) eq 'ARRAY') {
            @raw = @{$zigzag->{pivots}};
        }
        else {
            for my $segment (@{$zigzag->{segments} // []}) {
                push @raw,
                    { index => $segment->{start_index}, price => $segment->{start_price}, time => $segment->{start_time}, confirmed_at => $segment->{created_at} },
                    { index => $segment->{end_index},   price => $segment->{end_price},   time => $segment->{end_time},   confirmed_at => $segment->{completed_at} };
            }
            if (my $active = $zigzag->{active_segment}) {
                push @raw,
                    { index => $active->{start_index}, price => $active->{start_price}, time => $active->{start_time}, confirmed_at => $active->{created_at} },
                    { index => $active->{end_index},   price => $active->{end_price},   time => $active->{end_time},   confirmed_at => $active->{completed_at} };
            }
        }
    }
    else {
        return ();
    }

    my %seen;
    my @points = sort {
        $a->{index} <=> $b->{index} || $a->{price} <=> $b->{price}
    } grep {
        _valid_point($_)
            && $_->{index} <= $max_idx
            && (!defined $_->{confirmed_at} || $_->{confirmed_at} <= $max_idx)
            && (!exists $_->{confirmed} || $_->{confirmed})
            && !$seen{join '\x1e', $_->{index}, $_->{price}}++
    } @raw;
    return @points;
}

sub _valid_point {
    my ($point) = @_;
    return ref($point) eq 'HASH'
        && _number($point->{index}) && _number($point->{price});
}

sub _empty {
    my ($tf, $max_idx) = @_;
    return {
        timeframe => $tf, max_visible_index => $max_idx,
        direction => undef, shownlevels => 0, levels => [], replay_safe => 1,
    };
}

sub _round_to_mintick {
    my ($price, $tick) = @_;
    my $scaled = $price / $tick;
    return ($scaled >= 0 ? int($scaled + 0.5) : int($scaled - 0.5)) * $tick;
}

sub _fmt_ratio {
    my ($ratio) = @_;
    my $text = sprintf '%.3f', $ratio;
    $text =~ s/0+$//;
    $text =~ s/\.$//;
    return $text;
}

sub _fmt_price {
    my ($price, $tick) = @_;
    my $decimals = 2;
    if ($tick < 1 && "$tick" =~ /\.(\d+)/) {
        $decimals = length $1;
    }
    return sprintf '%.' . $decimals . 'f', $price;
}

sub _number {
    return defined($_[0]) && !ref($_[0])
        && "$_[0]" =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/
        && $_[0] == $_[0] && abs($_[0]) <= 1e300;
}
sub _positive_number { return _number($_[0]) && $_[0] > 0; }

1;
