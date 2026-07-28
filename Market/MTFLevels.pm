package Market::MTFLevels;

use strict;
use warnings;
use POSIX qw(floor);


sub new {
    my ($class, %args) = @_;
    return bless {
        session_offset_seconds => $args{session_offset_seconds} // 0,
        session_start_minute   => $args{session_start_minute} // 0,
    }, $class;
}

sub previous_high_low_levels {
    my ($self, %args) = @_;
    my $candles = $args{candles} // [];
    return [] unless @$candles;

    my $reference_index = defined $args{reference_index}
        ? int($args{reference_index}) : $#$candles;
    $reference_index = $#$candles if $reference_index > $#$candles;
    return [] if $reference_index < 0;

    my $periods = $args{periods} // [qw(D W)];
    my @levels;
    for my $period (@$periods) {
        next unless $period eq 'D' || $period eq 'W';
        push @levels, @{ $self->_previous_levels_for_period(
            $candles, $reference_index, $period,
        ) };
    }
    return \@levels;
}

sub _previous_levels_for_period {
    my ($self, $candles, $reference_index, $period) = @_;
    my %groups;

    for my $i (0 .. $reference_index) {
        my $c = $candles->[$i] // next;
        next unless defined $c->{time} && defined $c->{high} && defined $c->{low};
        my ($key, $sequence) = $self->_period_key($c->{time}, $period);
        next unless defined $key;

        my $group = $groups{$key} //= {
            key => $key, sequence => $sequence,
            start_index => $i, end_index => $i,
            high => $c->{high}, low => $c->{low},
            high_index => $i, low_index => $i,
            high_time => $c->{time}, low_time => $c->{time},
        };
        $group->{end_index} = $i;
        if ($c->{high} > $group->{high}) {
            @{$group}{qw(high high_index high_time)} = ($c->{high}, $i, $c->{time});
        }
        if ($c->{low} < $group->{low}) {
            @{$group}{qw(low low_index low_time)} = ($c->{low}, $i, $c->{time});
        }
    }

    my $reference = $candles->[$reference_index] or return [];
    my ($current_key, $current_sequence) = $self->_period_key($reference->{time}, $period);
    return [] unless defined $current_key;
    my @previous = sort { $b->{sequence} <=> $a->{sequence} } grep {
        $_->{sequence} < $current_sequence
    } values %groups;
    return [] unless @previous;

    my $previous = $previous[0];
    my $current = $groups{$current_key};
    my $available_at = $current ? $current->{start_index} : $reference_index;
    my ($prefix, $name) = $period eq 'D' ? ('PD', 'D') : ('PW', 'W');

    return [
        _level($prefix . 'H', $prefix . 'H', $name, $previous, 'high', $available_at),
        _level($prefix . 'L', $prefix . 'L', $name, $previous, 'low',  $available_at),
    ];
}

sub _level {
    my ($type, $label, $period, $group, $side, $available_at) = @_;
    my $price = $side eq 'high' ? $group->{high} : $group->{low};
    my $index = $side eq 'high' ? $group->{high_index} : $group->{low_index};
    my $time  = $side eq 'high' ? $group->{high_time} : $group->{low_time};
    return {
        id                 => join(':', $type, $group->{key}),
        type               => $type,
        label              => $label,
        source_timeframe   => $period,
        source_period_key  => $group->{key},
        price              => $price + 0,
        anchor_index       => $index,
        anchor_time        => $time,
        available_at       => $available_at,
        active             => 1,
        replay_safe        => 1,
    };
}

sub _period_key {
    my ($self, $epoch, $period) = @_;
    return unless defined $epoch;
    my $session_epoch = $epoch + ($self->{session_offset_seconds} // 0)
        - (($self->{session_start_minute} // 0) * 60);
    my $day = floor($session_epoch / 86_400);
    return ("D:$day", $day) if $period eq 'D';

    my @utc = gmtime($session_epoch);
    my $monday_offset = $utc[6] == 0 ? 6 : $utc[6] - 1;
    my $week = $day - $monday_offset;
    return ("W:$week", $week) if $period eq 'W';
    return;
}

1;
