package Market::Indicators::TrendChannels;

use strict;
use warnings;

use List::Util qw(max min);
use Time::Local qw(timegm);

# Detector causal de canales paralelos. Recibe solo velas visibles y pivotes
# ya confirmados; por eso una ejecución sobre un prefijo de datos no puede
# producir canales que dependan de velas futuras.

my %DEFAULT = (
    pivot_left                    => 3,
    pivot_right                   => 3,
    minimum_duration_minutes      => 60,
    minimum_candles               => 8,
    contact_tolerance_atr         => 0.15,
    breakout_tolerance_atr        => 0.25,
    strong_breakout_tolerance_atr => 0.40,
    contact_merge_bars            => 3,
    contact_merge_minutes         => 10,
    minimum_main_line_touches     => 2,
    minimum_opposite_line_touches => 2,
    minimum_total_touches         => 4,
    minimum_containment_ratio     => 0.85,
    minimum_width_atr             => 0.75,
    maximum_width_atr             => 8.0,
    minimum_directional_move_atr  => 0.50,
    maximum_pivot_lookback        => 20,
    minimum_score                 => 0.70,
    maximum_channels              => 3,
);

sub new {
    my ($class, %args) = @_;
    my %config = (%DEFAULT, map { $_ => $args{$_} } grep { exists $args{$_} } keys %DEFAULT);
    return bless { config => \%config }, $class;
}

sub compute {
    my ($class_or_self, %args) = @_;
    my $self = ref($class_or_self) ? $class_or_self : $class_or_self->new;
    my %cfg = (%{ $self->{config} // \%DEFAULT });
    for my $key (keys %DEFAULT) {
        $cfg{$key} = $args{$key} if exists $args{$key};
    }
    _normalise_config(\%cfg);

    my $candles = $args{candles};
    return [] unless ref($candles) eq 'ARRAY' && @$candles;
    return [] if defined($args{max_visible_index})
        && $args{max_visible_index} !~ /^-?\d+$/;
    my $max_idx = defined $args{max_visible_index} ? int($args{max_visible_index}) : $#$candles;
    $max_idx = $#$candles if $max_idx > $#$candles;
    return [] if $max_idx < $cfg{minimum_candles} - 1;

    my $series = _normalise_series($candles, $max_idx, $args{atr_series});
    return [] unless $series;
    return [] unless ($series->[-1]{time_s} - $series->[0]{time_s}) >= $cfg{minimum_duration_minutes} * 60;

    my @pivots = _normalise_provided_pivots($args{pivots}, $series, $max_idx);
    push @pivots, _find_confirmed_pivots($series, \%cfg);
    @pivots = _dedupe_pivots(\@pivots);
    return [] unless @pivots >= 3;

    my @lows  = grep { $_->{kind} eq 'low'  } @pivots;
    my @highs = grep { $_->{kind} eq 'high' } @pivots;
    my @candidates;
    push @candidates, @{ _candidates_for_side('bullish', 'low',  \@lows,  \@highs, $series, \%cfg) };
    push @candidates, @{ _candidates_for_side('bearish', 'high', \@highs, \@lows,  $series, \%cfg) };
    return [] unless @candidates;

    @candidates = sort {
        $b->{score} <=> $a->{score}
            || $b->{end_index} <=> $a->{end_index}
            || $b->{confirmed_at} <=> $a->{confirmed_at}
            || $a->{start_index} <=> $b->{start_index}
    } @candidates;
    my @out;
    for my $channel (@candidates) {
        next if grep { _duplicate_channel($_, $channel) } @out;
        push @out, $channel;
        last if @out >= $cfg{maximum_channels};
    }
    return \@out;
}

sub _normalise_config {
    my ($cfg) = @_;
    for my $key (qw(pivot_left pivot_right minimum_candles contact_merge_bars
                    contact_merge_minutes minimum_main_line_touches
                    minimum_opposite_line_touches minimum_total_touches
                    maximum_pivot_lookback maximum_channels)) {
        $cfg->{$key} = $DEFAULT{$key}
            unless defined($cfg->{$key}) && $cfg->{$key} =~ /^-?\d+$/;
        $cfg->{$key} = int($cfg->{$key});
        $cfg->{$key} = 1 if $cfg->{$key} < 1;
    }
    for my $key (qw(minimum_duration_minutes contact_tolerance_atr
                    breakout_tolerance_atr strong_breakout_tolerance_atr
                    minimum_containment_ratio minimum_width_atr maximum_width_atr
                    minimum_directional_move_atr minimum_score)) {
        $cfg->{$key} = $DEFAULT{$key} unless _finite($cfg->{$key});
        $cfg->{$key} += 0;
    }
    $cfg->{minimum_containment_ratio} = 0 if $cfg->{minimum_containment_ratio} < 0;
    $cfg->{minimum_containment_ratio} = 1 if $cfg->{minimum_containment_ratio} > 1;
    $cfg->{maximum_width_atr} = $cfg->{minimum_width_atr}
        if $cfg->{maximum_width_atr} < $cfg->{minimum_width_atr};
    return;
}

sub _normalise_series {
    my ($candles, $max_idx, $atr_series) = @_;
    return undef if defined($atr_series) && ref($atr_series) ne 'ARRAY';
    my (@out, $previous_time);
    for my $index (0 .. $max_idx) {
        my $c = $candles->[$index];
        return undef unless ref($c) eq 'HASH';
        for my $field (qw(open high low close volume)) {
            return undef unless _finite($c->{$field});
        }
        my ($open, $high, $low, $close) = map { $c->{$_} + 0 } qw(open high low close);
        return undef if $high < $low || $open < $low || $open > $high || $close < $low || $close > $high;
        my $time_s = _time_seconds($c->{time});
        return undef unless defined $time_s;
        return undef if defined($previous_time) && $time_s <= $previous_time;
        $previous_time = $time_s;
        my $atr = $atr_series && _finite($atr_series->[$index]) && $atr_series->[$index] > 0
            ? $atr_series->[$index] + 0 : $high - $low;
        push @out, {
            %$c, index => $index, time_s => $time_s,
            open => $open, high => $high, low => $low, close => $close,
            volume => $c->{volume} + 0, atr => $atr,
        };
    }
    return \@out;
}

sub _normalise_provided_pivots {
    my ($pivots, $series, $max_idx) = @_;
    return () unless ref($pivots) eq 'ARRAY';
    my @out;
    for my $pivot (@$pivots) {
        next unless ref($pivot) eq 'HASH';
        my $kind = $pivot->{kind} // $pivot->{type} // '';
        next unless $kind eq 'high' || $kind eq 'low';
        next unless defined($pivot->{index}) && $pivot->{index} =~ /^\d+$/ && _finite($pivot->{price});
        my $index = int($pivot->{index});
        next if $index > $#$series;
        next if defined($pivot->{confirmed_at}) && $pivot->{confirmed_at} !~ /^\d+$/;
        my $confirmed_at = defined($pivot->{confirmed_at}) ? int($pivot->{confirmed_at}) : $index;
        next if $confirmed_at < $index || $confirmed_at > $max_idx;
        next if exists($pivot->{confirmed}) && !$pivot->{confirmed};
        push @out, {
            id => $pivot->{id} // join('_', 'channel', $kind, $index, $confirmed_at),
            kind => $kind, index => $index, price => $pivot->{price} + 0,
            time => $series->[$index]{time}, time_s => $series->[$index]{time_s},
            confirmed_at => $confirmed_at, confirmed => 1, source => 'provided',
        };
    }
    return @out;
}

sub _find_confirmed_pivots {
    my ($series, $cfg) = @_;
    my ($left, $right) = @{$cfg}{qw(pivot_left pivot_right)};
    my @out;
    for my $index ($left .. $#$series - $right) {
        my ($high, $low) = @{$series->[$index]}{qw(high low)};
        my ($is_high, $is_low) = (1, 1);
        for my $offset (1 .. $left) {
            $is_high = 0 if $high <= $series->[$index - $offset]{high};
            $is_low  = 0 if $low  >= $series->[$index - $offset]{low};
        }
        for my $offset (1 .. $right) {
            $is_high = 0 if $high <= $series->[$index + $offset]{high};
            $is_low  = 0 if $low  >= $series->[$index + $offset]{low};
        }
        # Una misma vela exterior no aporta dos anclajes temporales distintos.
        next if $is_high && $is_low;
        for my $kind ($is_high ? 'high' : (), $is_low ? 'low' : ()) {
            push @out, {
                id => join('_', 'channel', $kind, $index, $index + $right),
                kind => $kind, index => $index,
                price => $kind eq 'high' ? $high : $low,
                time => $series->[$index]{time}, time_s => $series->[$index]{time_s},
                confirmed_at => $index + $right, confirmed => 1, source => 'derived',
            };
        }
    }
    return @out;
}

sub _dedupe_pivots {
    my ($pivots) = @_;
    my (%seen, @out);
    for my $pivot (sort {
        $a->{index} <=> $b->{index} || $a->{kind} cmp $b->{kind} || $a->{source} cmp $b->{source}
    } @$pivots) {
        my $key = join ':', $pivot->{kind}, $pivot->{index}, sprintf('%.10f', $pivot->{price});
        next if $seen{$key}++;
        push @out, $pivot;
    }
    return @out;
}

sub _candidates_for_side {
    my ($direction, $base_kind, $base_points, $opposite_points, $series, $cfg) = @_;
    return [] unless @$base_points >= 2 && @$opposite_points;
    my @base = @$base_points;
    @base = @base[-$cfg->{maximum_pivot_lookback} .. -1] if @base > $cfg->{maximum_pivot_lookback};
    my @out;
    for my $a_index (0 .. $#base - 1) {
        for my $b_index ($a_index + 1 .. $#base) {
            my ($a, $b) = @base[$a_index, $b_index];
            next if $b->{index} <= $a->{index};
            my $move = $b->{price} - $a->{price};
            next if $direction eq 'bullish' && $move <= 0;
            next if $direction eq 'bearish' && $move >= 0;
            my $average_atr = _average_atr($series, $a->{index}, $b->{index});
            next unless $average_atr > 0 && abs($move) >= $average_atr * $cfg->{minimum_directional_move_atr};
            my $slope = $move / ($b->{index} - $a->{index});
            for my $opposite (@$opposite_points) {
                next if $opposite->{index} < $a->{index} || $opposite->{index} > $#$series;
                my $base_y = $a->{price} + $slope * ($opposite->{index} - $a->{index});
                my $offset = $opposite->{price} - $base_y;
                next if $base_kind eq 'low'  && $offset <= 0;
                next if $base_kind eq 'high' && $offset >= 0;
                my $width = abs $offset;
                my $width_atr = _average_atr($series, $a->{index}, $opposite->{index});
                next unless $width_atr > 0;
                my $width_in_atr = $width / $width_atr;
                next if $width_in_atr < $cfg->{minimum_width_atr} || $width_in_atr > $cfg->{maximum_width_atr};
                my $channel = _evaluate_candidate(
                    direction => $direction, base_kind => $base_kind, a => $a, b => $b,
                    opposite => $opposite, slope => $slope, offset => $offset,
                    series => $series, config => $cfg,
                );
                push @out, $channel if $channel;
            }
        }
    }
    return \@out;
}

sub _evaluate_candidate {
    my (%args) = @_;
    my ($a, $b, $opposite, $series, $cfg) = @args{qw(a b opposite series config)};
    my $confirmed_at = max($a->{confirmed_at}, $b->{confirmed_at}, $opposite->{confirmed_at});
    my $last_anchor = max($b->{index}, $opposite->{index});
    return undef if $confirmed_at > $#$series;
    my $pre_break = _break_info(\%args, $a->{index} + 1, $confirmed_at);
    return undef if $pre_break && $pre_break->{index} < $last_anchor;
    my $break = _break_info(\%args, $confirmed_at + 1, $#$series);
    my $end = $break ? $break->{index} : $#$series;
    return undef if $end < $last_anchor || $end <= $a->{index};
    my $duration = $series->[$end]{time_s} - $series->[$a->{index}]{time_s};
    return undef if $duration < $cfg->{minimum_duration_minutes} * 60;
    return undef if $end - $a->{index} + 1 < $cfg->{minimum_candles};

    my $atr = _average_atr($series, $a->{index}, $end);
    return undef unless $atr > 0;
    my $width = abs($args{offset});
    my $width_in_atr = $width / $atr;
    return undef if $width_in_atr < $cfg->{minimum_width_atr} || $width_in_atr > $cfg->{maximum_width_atr};
    my $touches = _touch_summary(\%args, $a->{index}, $end);
    my $main = $args{base_kind} eq 'low' ? $touches->{lower_count} : $touches->{upper_count};
    my $opposite_touches = $args{base_kind} eq 'low' ? $touches->{upper_count} : $touches->{lower_count};
    return undef if $main < $cfg->{minimum_main_line_touches}
                 || $opposite_touches < $cfg->{minimum_opposite_line_touches}
                 || $touches->{total_count} < $cfg->{minimum_total_touches};
    my $containment = _containment(\%args, $a->{index}, $end);
    return undef if $containment < $cfg->{minimum_containment_ratio};
    my $touch_distribution = _touch_distribution($touches, $a->{index}, $end);
    my $score = _score($touches, $containment, $duration, $width_in_atr,
        $touch_distribution, $cfg);
    return undef if $score < $cfg->{minimum_score};

    my ($lower_start, $upper_start) = _bounds(\%args, $a->{index});
    my ($lower_end, $upper_end) = _bounds(\%args, $end);
    return {
        id => join('_', 'trend_channel', $args{direction}, $a->{index}, $b->{index}, $opposite->{index}),
        type => 'trend_channel', automatic => 1, replay_safe => 1,
        direction => $args{direction}, base_kind => $args{base_kind},
        start_index => $a->{index}, start_time => $series->[$a->{index}]{time},
        end_index => $end, end_time => $series->[$end]{time},
        lower_y1 => $lower_start + 0, lower_y2 => $lower_end + 0,
        upper_y1 => $upper_start + 0, upper_y2 => $upper_end + 0,
        center_y1 => (($lower_start + $upper_start) / 2) + 0,
        center_y2 => (($lower_end + $upper_end) / 2) + 0,
        slope_per_index => $args{slope} + 0, width => $width + 0,
        width_in_atr => sprintf('%.4f', $width_in_atr) + 0,
        containment_ratio => sprintf('%.4f', $containment) + 0,
        upper_touches => $touches->{upper_count}, lower_touches => $touches->{lower_count},
        total_touches => $touches->{total_count}, score => sprintf('%.4f', $score) + 0,
        touch_distribution_ratio => sprintf('%.4f', $touch_distribution) + 0,
        duration_minutes => sprintf('%.2f', $duration / 60) + 0,
        confirmed_at => $confirmed_at, confirmed_time => $series->[$confirmed_at]{time},
        status => $break ? 'broken' : 'confirmed', active => $break ? 0 : 1,
        break_index => $break ? $break->{index} : undef,
        breakout_direction => $break ? $break->{direction} : undef,
        anchor1 => _anchor($a), anchor2 => _anchor($b), opposite_anchor => _anchor($opposite),
        source_a_index => $a->{index}, source_b_index => $b->{index}, opposite_index => $opposite->{index},
    };
}

sub _anchor {
    my ($pivot) = @_;
    return { index => $pivot->{index}, time => $pivot->{time}, price => $pivot->{price} + 0,
             confirmed => 1, confirmed_at => $pivot->{confirmed_at}, pivot_id => $pivot->{id} };
}

sub _bounds {
    my ($args, $index) = @_;
    my $base = $args->{a}{price} + $args->{slope} * ($index - $args->{a}{index});
    my $other = $base + $args->{offset};
    return $base <= $other ? ($base, $other) : ($other, $base);
}

sub _break_info {
    my ($args, $from, $to) = @_;
    my ($series, $cfg) = @{$args}{qw(series config)};
    return undef if $from > $to;
    my ($last_direction, $run) = ('', 0);
    for my $index ($from .. $to) {
        my ($lower, $upper) = _bounds($args, $index);
        my $atr = $series->[$index]{atr};
        next unless $atr > 0;
        my $direction = '';
        my $strong = 0;
        if ($series->[$index]{close} > $upper + $atr * $cfg->{breakout_tolerance_atr}) {
            $direction = 'up';
            $strong = 1 if $series->[$index]{close} > $upper + $atr * $cfg->{strong_breakout_tolerance_atr};
        }
        elsif ($series->[$index]{close} < $lower - $atr * $cfg->{breakout_tolerance_atr}) {
            $direction = 'down';
            $strong = 1 if $series->[$index]{close} < $lower - $atr * $cfg->{strong_breakout_tolerance_atr};
        }
        return { index => $index, direction => $direction } if $strong;
        if ($direction ne '') {
            $run = $direction eq $last_direction ? $run + 1 : 1;
            $last_direction = $direction;
            return { index => $index, direction => $direction } if $run >= 2;
        } else {
            ($last_direction, $run) = ('', 0);
        }
    }
    return undef;
}

sub _touch_summary {
    my ($args, $start, $end) = @_;
    my (@upper, @lower);
    for my $index ($start .. $end) {
        my ($lo, $hi) = _bounds($args, $index);
        my $tol = $args->{series}[$index]{atr} * $args->{config}{contact_tolerance_atr};
        push @upper, { index => $index, time_s => $args->{series}[$index]{time_s}, price => $args->{series}[$index]{high} }
            if abs($args->{series}[$index]{high} - $hi) <= $tol;
        push @lower, { index => $index, time_s => $args->{series}[$index]{time_s}, price => $args->{series}[$index]{low} }
            if abs($args->{series}[$index]{low} - $lo) <= $tol;
    }
    @upper = _merge_contacts(\@upper, $args->{config});
    @lower = _merge_contacts(\@lower, $args->{config});
    return { upper => \@upper, lower => \@lower, upper_count => scalar(@upper), lower_count => scalar(@lower), total_count => scalar(@upper) + scalar(@lower) };
}

sub _merge_contacts {
    my ($contacts, $cfg) = @_;
    my @out;
    for my $contact (@$contacts) {
        if (!@out) { push @out, { %$contact }; next; }
        my $last = $out[-1];
        my $bars = $contact->{index} - $last->{index};
        my $minutes = ($contact->{time_s} - $last->{time_s}) / 60;
        if ($bars < $cfg->{contact_merge_bars} || $minutes < $cfg->{contact_merge_minutes}) {
            $out[-1] = { %$contact };
        } else {
            push @out, { %$contact };
        }
    }
    return @out;
}

sub _containment {
    my ($args, $start, $end) = @_;
    my ($inside, $total) = (0, 0);
    for my $index ($start .. $end) {
        my ($lo, $hi) = _bounds($args, $index);
        my $tol = $args->{series}[$index]{atr} * $args->{config}{contact_tolerance_atr};
        $inside++ if $args->{series}[$index]{close} >= $lo - $tol && $args->{series}[$index]{close} <= $hi + $tol;
        $total++;
    }
    return $total ? $inside / $total : 0;
}

sub _score {
    my ($touches, $containment, $duration, $width, $distribution, $cfg) = @_;
    my $touch_score = min(1, $touches->{total_count} / $cfg->{minimum_total_touches});
    $touch_score *= 0.75 + 0.25 * $distribution;
    my $duration_score = min(1, $duration / ($cfg->{minimum_duration_minutes} * 60 * 2));
    my $middle = ($cfg->{minimum_width_atr} + $cfg->{maximum_width_atr}) / 2;
    my $width_score = 1 - min(1, abs($width - $middle) / max(0.001, $middle));
    return $touch_score * 0.35 + $containment * 0.35 + $duration_score * 0.15 + $width_score * 0.15;
}

sub _touch_distribution {
    my ($touches, $start, $end) = @_;
    my @all = sort { $a->{index} <=> $b->{index} }
        (@{ $touches->{upper} // [] }, @{ $touches->{lower} // [] });
    return 0 if @all < 2 || $end <= $start;
    my $ratio = ($all[-1]{index} - $all[0]{index}) / ($end - $start);
    $ratio = 0 if $ratio < 0;
    $ratio = 1 if $ratio > 1;
    return $ratio;
}

sub _average_atr {
    my ($series, $from, $to) = @_;
    return 0 if $from > $to;
    my ($sum, $count) = (0, 0);
    for my $index ($from .. $to) {
        next unless $series->[$index]{atr} > 0;
        $sum += $series->[$index]{atr};
        $count++;
    }
    return $count ? $sum / $count : 0;
}

sub _duplicate_channel {
    my ($a, $b) = @_;
    return 0 unless $a->{direction} eq $b->{direction};
    my $start = max($a->{start_index}, $b->{start_index});
    my $end = min($a->{end_index}, $b->{end_index});
    return 0 if $end <= $start;
    my $overlap = ($end - $start) / min(max(1, $a->{end_index} - $a->{start_index}), max(1, $b->{end_index} - $b->{start_index}));
    return 0 if $overlap < 0.70;
    return 0 if abs($a->{slope_per_index} - $b->{slope_per_index}) / max(0.000001, abs($a->{slope_per_index}), abs($b->{slope_per_index})) > 0.18;
    return abs($a->{width} - $b->{width}) / max(0.000001, $a->{width}, $b->{width}) <= 0.30 ? 1 : 0;
}

sub _time_seconds {
    my ($value) = @_;
    return undef unless defined $value && !ref $value;
    return $value + 0 if $value =~ /^[-+]?\d+(?:\.\d+)?$/ && abs($value) < 100_000_000_000;
    return ($value + 0) / 1000 if $value =~ /^[-+]?\d+(?:\.\d+)?$/;
    return undef unless $value =~ /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:\.\d+)?(Z|[+-]\d{2}:?\d{2})?$/i;
    my ($year, $month, $day, $hour, $minute, $second, $zone)
        = ($1, $2, $3, $4, $5, $6 // 0, $7);
    my $epoch = eval { timegm($second + 0, $minute + 0, $hour + 0,
        $day + 0, $month - 1, $year - 1900) };
    return undef if !defined($epoch) || $@;
    if (defined($zone) && uc($zone) ne 'Z') {
        return undef unless $zone =~ /^([+-])(\d{2}):?(\d{2})$/;
        my $offset = ($2 * 60 + $3) * 60;
        $epoch += $1 eq '+' ? -$offset : $offset;
    }
    return $epoch;
}

sub _finite {
    my ($value) = @_;
    return 0 unless defined $value && !ref($value) && "$value" =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/;
    my $number = $value + 0;
    return $number == $number && abs($number) <= 1e300;
}

1;
