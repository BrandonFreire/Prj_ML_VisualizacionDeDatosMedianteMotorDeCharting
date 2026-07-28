package Market::ML::GhostFeatureExtractor;

use strict;
use warnings;

use List::Util qw(max min sum);
use POSIX qw(floor);
use Time::Local qw(timegm);

use Market::MarketData;
use Market::Indicators::Liquidity;
use Market::Indicators::PivotMissedReversal;
use Market::Indicators::SMC_Structures;


my @TARGET_WINDOWS = (3, 5, 10, 15);
my @TIMEFRAMES     = (1, 10, 60);

sub new {
    my ($class, %args) = @_;
    my $pip_size = $args{pip_size} // 0.25;
    die 'GhostFeatureExtractor: pip_size debe ser positivo'
        unless _finite($pip_size) && $pip_size > 0;
    my $ghost_length = $args{ghost_length} // 50;
    die 'GhostFeatureExtractor: ghost_length debe ser un entero positivo'
        unless defined($ghost_length) && $ghost_length =~ /^\d+$/ && $ghost_length > 0;

    return bless {
        pip_size      => $pip_size + 0,
        ghost_length  => int($ghost_length),
        atr_period    => int($args{atr_period} // 14),
        ema_period    => int($args{ema_period} // 9),
        smc_depth     => int($args{smc_depth} // 3),
        external_depth => int($args{external_depth} // 10),
        vp_bins       => int($args{vp_bins} // 50),
        channel_atr_price_max => $args{channel_atr_price_max} // 0.005,
    }, $class;
}

sub metadata_columns {
    return [qw(
        event_id event_timestamp event_date event_hour event_minute
        event_index ghost_index complete
    )];
}

sub feature_columns {
    my @columns = qw(
        ghost_price ghost_hlc3 atr_1m volume_1m volume_ema9_1m
    );
    for my $tf (@TIMEFRAMES) {
        push @columns,
            "tf${tf}_ob_dist_pips", "tf${tf}_ob_width_pips",
            "tf${tf}_fvg_dist_pips", "tf${tf}_fvg_width_pips",
            "tf${tf}_fib_dist_pips",
            "tf${tf}_vwap_dist_pips",
            "tf${tf}_vwap_band1_dist_pips",
            "tf${tf}_vwap_band2_dist_pips",
            "tf${tf}_vp_poc_dist_pips",
            "tf${tf}_vp_vah_dist_pips",
            "tf${tf}_vp_val_dist_pips",
            "tf${tf}_bos_choch_dist_pips",
            "tf${tf}_eqh_eql_dist_pips",
            "tf${tf}_sweep_grab_run_dist_pips",
            "tf${tf}_supply_demand_dist_pips",
            "tf${tf}_supply_demand_width_pips",
            "tf${tf}_channel_dist_pips",
            "tf${tf}_channel_width_pips";
    }
    push @columns, qw(
        sr_4h_dist_pips sr_d_dist_pips sr_w_dist_pips
        ghost_type relocation
    );
    return \@columns;
}

sub target_columns {
    return [ map { "Y_${_}m" } @TARGET_WINDOWS ];
}

sub load_csv {
    my ($class_or_self, $path) = @_;
    open my $fh, '<', $path or die "No se puede abrir $path: $!";
    my $header = <$fh>;
    die "$path esta vacio" unless defined $header;
    chomp $header;
    $header =~ s/\r$//;
    my @header = split /,/, $header, -1;
    my %at;
    $at{lc $header[$_]} = $_ for 0 .. $#header;
    for my $required (qw(time open high low close volume)) {
        die "$path no contiene la columna obligatoria '$required'"
            unless exists $at{$required};
    }

    my (@bars, $previous_time, $timezone_offset);
    my $line_number = 1;
    while (my $line = <$fh>) {
        $line_number++;
        chomp $line;
        $line =~ s/\r$//;
        next if $line =~ /^\s*$/;
        my @field = split /,/, $line, -1;
        my ($epoch, $offset, $date, $hour, $minute) =
            _parse_timestamp($field[$at{time}]);
        die "$path:$line_number timestamp invalido: $field[$at{time}]"
            unless defined $epoch;
        die "$path:$line_number no esta ordenado cronologicamente"
            if defined($previous_time) && $epoch <= $previous_time;
        $previous_time = $epoch;
        $timezone_offset //= $offset;

        my %bar = (
            datetime => $field[$at{time}],
            time     => $epoch,
            date     => $date,
            hour     => $hour,
            minute   => $minute,
            timezone_offset => $offset,
        );
        for my $name (qw(open high low close volume)) {
            my $value = $field[$at{$name}];
            die "$path:$line_number $name no es numerico finito"
                unless _finite($value);
            $bar{$name} = $value + 0;
        }
        die "$path:$line_number contiene OHLC inconsistente"
            if $bar{high} < $bar{low}
                || $bar{open} < $bar{low} || $bar{open} > $bar{high}
                || $bar{close} < $bar{low} || $bar{close} > $bar{high}
                || $bar{volume} < 0;
        push @bars, \%bar;
    }
    close $fh;
    die "$path no contiene velas" unless @bars;
    return \@bars;
}

sub extract {
    my ($self, %args) = @_;
    my $bars = $args{bars} // [];
    die 'GhostFeatureExtractor::extract: bars debe ser un arrayref'
        unless ref($bars) eq 'ARRAY';
    return { rows => [], events => [], feature_columns => feature_columns() }
        unless @$bars;

    my $atr = _compute_atr($bars, $self->{atr_period});
    my @volume = map { $_->{volume} + 0 } @$bars;
    my $ema_volume = _compute_ema(\@volume, $self->{ema_period});

    my $events = $self->detect_ghost_relocations($bars);
    $self->label_future_relocations($events, $bars->[-1]{time});

    my %contexts;
    for my $tf (@TIMEFRAMES) {
        my $aggregated = _aggregate_bars($bars, $tf);
        $contexts{$tf} = $self->_prepare_context($aggregated, $tf);
    }
    my $sr = _prepare_support_resistance($bars);

    my @rows;
    for my $event (@$events) {
        next unless $event->{complete} || $args{include_incomplete};
        my $event_index = $event->{event_index};
        my $bar = $bars->[$event_index] // next;
        next unless defined $atr->[$event_index]
            && defined $ema_volume->[$event_index];
        my $ghost_bar = $bars->[ $event->{ghost_index} ] // next;
        my $ghost_hlc3 =
            ($ghost_bar->{high} + $ghost_bar->{low} + $ghost_bar->{close}) / 3;
        my %row = (
            %$event,
            event_timestamp => $bar->{time},
            event_date      => $bar->{date},
            event_hour      => $bar->{hour},
            event_minute    => $bar->{minute},
            ghost_hlc3      => $ghost_hlc3,
            atr_1m          => $atr->[$event_index],
            volume_1m       => $bar->{volume},
            volume_ema9_1m  => $ema_volume->[$event_index],
        );

        for my $tf (@TIMEFRAMES) {
            my $snapshot = $self->_snapshot(
                $contexts{$tf}, $bar->{time}, $ghost_hlc3,
            );
            @row{keys %$snapshot} = values %$snapshot;
        }
        my $sr_values = _support_resistance_at(
            $sr, $bar->{time}, $bar->{timezone_offset}, $ghost_hlc3,
            $self->{pip_size},
        );
        @row{keys %$sr_values} = values %$sr_values;
        push @rows, \%row;
    }

    return {
        rows             => \@rows,
        events           => $events,
        feature_columns  => feature_columns(),
        metadata_columns => metadata_columns(),
        target_columns   => target_columns(),
    };
}

sub detect_ghost_relocations {
    my ($self, $bars) = @_;
    my $indicator = Market::Indicators::PivotMissedReversal->new(
        length => $self->{ghost_length}, show_regular => 1, show_missed => 1,
    );
    my $result = $indicator->compute(candles => $bars);
    my @events = map { +{ %$_ } } @{ $result->{trace_events} // [] };
    for my $event (@events) {
        my $bar = $bars->[ $event->{event_index} ];
        $event->{_event_time}    = $bar->{time};
        $event->{event_timestamp} = $bar->{time};
        $event->{event_date}      = $bar->{date};
        $event->{event_hour}      = $bar->{hour};
        $event->{event_minute}    = $bar->{minute};
    }
    return \@events;
}

sub label_future_relocations {
    my ($self, $events, $last_timestamp) = @_;
    for my $i (0 .. $#$events) {
        my $timestamp = $events->[$i]{event_timestamp};
        $timestamp = $events->[$i]{_event_time} unless defined $timestamp;
        next unless defined $timestamp;
        for my $window (@TARGET_WINDOWS) {
            my $limit = $timestamp + $window * 60;
            my $cursor = _event_upper_bound($events, $i + 1, $limit);
            my $count = max(0, $cursor - ($i + 1));
            $events->[$i]{"Y_${window}m"} = $count;
        }
        $events->[$i]{complete} =
            defined($last_timestamp)
            && $last_timestamp >= $timestamp + $TARGET_WINDOWS[-1] * 60 ? 1 : 0;
    }
    return $events;
}

sub write_csv {
    my ($self, $path, $result) = @_;
    my @columns = (
        @{ $result->{metadata_columns} // metadata_columns() },
        @{ $result->{feature_columns}  // feature_columns() },
        @{ $result->{target_columns}   // target_columns() },
    );
    open my $fh, '>', $path or die "No se puede escribir $path: $!";
    print {$fh} join(',', @columns), "\n";
    for my $row (@{ $result->{rows} // [] }) {
        print {$fh} join(',', map { _csv_value($row->{$_}) } @columns), "\n";
    }
    close $fh or die "No se pudo cerrar $path: $!";
    return scalar @{ $result->{rows} // [] };
}

sub _prepare_context {
    my ($self, $bars, $tf) = @_;
    my $market = Market::MarketData->new();
    $market->add_candle($_) for @$bars;

    my $liquidity = Market::Indicators::Liquidity->new(
        depth => $self->{smc_depth}, external_depth => $self->{external_depth},
        atr_period => $self->{atr_period},
    );
    $liquidity->compute_all($market);

    my $smc = Market::Indicators::SMC_Structures->new(
        depth => $self->{smc_depth}, external_depth => $self->{external_depth},
    );
    $smc->set_liquidity_indicator($liquidity);
    $smc->compute_all($market);

    my @external = sort {
        ($a->{confirmed_at} // 0) <=> ($b->{confirmed_at} // 0)
            || $a->{index} <=> $b->{index}
    } (
        @{ $smc->get_external_swing_highs() // [] },
        @{ $smc->get_external_swing_lows() // [] },
    );
    my $atr = _compute_atr($bars, $self->{atr_period});
    my $prefix = _weighted_prefix($bars);
    my $supply_demand = _causal_supply_demand(
        $smc->get_ob_zones() // [], $bars,
    );
    my $channels = $self->_build_causal_channels(
        $bars, $atr,
        [ @{ $smc->get_swing_highs() // [] }, @{ $smc->get_swing_lows() // [] } ],
    );
    my @structure = (
        @{ $smc->get_bos_events() // [] },
        @{ $smc->get_choch_events() // [] },
    );
    my $levels = $liquidity->get_levels() // [];
    my @equal = grep {
        (($_->{is_eqh} // 0) || ($_->{is_eql} // 0))
            && defined($_->{eq_confirmed_at})
    } @$levels;
    my @resolved = grep {
        defined($_->{classification}) && defined($_->{resolved_at})
    } @$levels;

    return {
        tf         => $tf,
        bars       => $bars,
        atr        => $atr,
        prefix     => $prefix,
        smc        => $smc,
        liquidity  => $liquidity,
        external   => \@external,
        supply_demand => $supply_demand,
        channels   => $channels,
        profile_cache => {},
        streams => {
            ob => _make_stream(
                $smc->get_ob_zones() // [],
                sub { $_[0]{confirmed_at} },
                sub { $_[0]{end_index} },
            ),
            fvg => _make_stream(
                $smc->get_fvg_zones() // [],
                sub { $_[0]{formed_at} // $_[0]{confirmed_at} },
                sub { $_[0]{mitigated_at} // $_[0]{end_index} },
            ),
            external => _make_stream(
                \@external,
                sub { $_[0]{confirmed_at} // $_[0]{index} },
                undef,
            ),
            structure => _make_stream(
                \@structure,
                sub { $_[0]{confirmed_at} // $_[0]{index} },
                undef, 500,
            ),
            equal => _make_stream(
                \@equal,
                sub { $_[0]{eq_confirmed_at} },
                sub { $_[0]{swept_at} },
            ),
            resolved => _make_stream(
                \@resolved,
                sub { $_[0]{resolved_at} },
                undef, 500,
            ),
            supply_demand => _make_stream(
                $supply_demand,
                sub { $_[0]{confirmed_at} },
                sub { $_[0]{end_index} },
            ),
            channel => _make_stream(
                $channels,
                sub { $_[0]{confirmed_at} },
                sub { $_[0]{break_at} },
            ),
        },
    };
}

sub _snapshot {
    my ($self, $context, $event_time, $reference_price) = @_;
    my $tf = $context->{tf};
    my $cursor = _last_closed_index($context->{bars}, $event_time);
    my %out;
    my @names = qw(
        ob_dist_pips ob_width_pips fvg_dist_pips fvg_width_pips
        fib_dist_pips vwap_dist_pips vwap_band1_dist_pips
        vwap_band2_dist_pips vp_poc_dist_pips vp_vah_dist_pips
        vp_val_dist_pips bos_choch_dist_pips eqh_eql_dist_pips
        sweep_grab_run_dist_pips supply_demand_dist_pips
        supply_demand_width_pips channel_dist_pips channel_width_pips
    );
    @out{map { "tf${tf}_$_" } @names} = (undef) x @names;
    return \%out if $cursor < 0;

    my $smc = $context->{smc};
    my $ob = _nearest_zone(
        _advance_stream($context->{streams}{ob}, $cursor),
        $cursor, $reference_price,
        sub { $_[0]{confirmed_at} }, sub { $_[0]{end_index} },
    );
    if ($ob) {
        $out{"tf${tf}_ob_dist_pips"} =
            _signed_pips(($ob->{top} + $ob->{bottom}) / 2, $reference_price, $self->{pip_size});
        $out{"tf${tf}_ob_width_pips"} =
            abs($ob->{top} - $ob->{bottom}) / $self->{pip_size};
    }

    my $fvg = _nearest_zone(
        _advance_stream($context->{streams}{fvg}, $cursor),
        $cursor, $reference_price,
        sub { $_[0]{formed_at} // $_[0]{confirmed_at} },
        sub { $_[0]{mitigated_at} // $_[0]{end_index} },
    );
    if ($fvg) {
        $out{"tf${tf}_fvg_dist_pips"} =
            _signed_pips(($fvg->{top} + $fvg->{bottom}) / 2, $reference_price, $self->{pip_size});
        $out{"tf${tf}_fvg_width_pips"} =
            abs($fvg->{top} - $fvg->{bottom}) / $self->{pip_size};
    }

    my $eligible_pivots = _advance_stream(
        $context->{streams}{external}, $cursor,
    );
    my ($last, $previous) = _last_alternating_pivots($eligible_pivots);
    if ($last && $previous) {
        my ($low, $high) = (
            min($last->{price}, $previous->{price}),
            max($last->{price}, $previous->{price}),
        );
        my @fib = map { $low + ($high - $low) * $_ }
            (0.236, 0.382, 0.5, 0.618, 0.786);
        my $fib = _nearest_price(\@fib, $reference_price);
        $out{"tf${tf}_fib_dist_pips"} =
            _signed_pips($fib, $reference_price, $self->{pip_size});

        my ($vwap, $std_dev) = _anchored_vwap(
            $context->{prefix}, $previous->{index}, $cursor,
        );
        if (defined $vwap) {
            $out{"tf${tf}_vwap_dist_pips"} =
                _signed_pips($vwap, $reference_price, $self->{pip_size});
            my @band1 = ($vwap - $std_dev, $vwap + $std_dev);
            my @band2 = ($vwap - 2 * $std_dev, $vwap + 2 * $std_dev);
            $out{"tf${tf}_vwap_band1_dist_pips"} =
                _signed_pips(_nearest_price(\@band1, $reference_price), $reference_price, $self->{pip_size});
            $out{"tf${tf}_vwap_band2_dist_pips"} =
                _signed_pips(_nearest_price(\@band2, $reference_price), $reference_price, $self->{pip_size});
        }

        my ($start, $end) = (
            min($previous->{index}, $last->{index}),
            max($previous->{index}, $last->{index}),
        );
        my $profile = _volume_profile(
            $context, $start, $end, $self->{vp_bins},
        );
        if ($profile) {
            for my $level (qw(poc vah val)) {
                $out{"tf${tf}_vp_${level}_dist_pips"} =
                    _signed_pips($profile->{$level}, $reference_price, $self->{pip_size});
            }
        }
    }

    my $structure_price = _nearest_event_price(
        _advance_stream($context->{streams}{structure}, $cursor),
        $cursor, $reference_price, 'level', 'confirmed_at',
    );
    $out{"tf${tf}_bos_choch_dist_pips"} =
        _signed_pips($structure_price, $reference_price, $self->{pip_size})
        if defined $structure_price;

    my @equal_prices = map { $_->{eq_price} // $_->{price} }
        @{ _advance_stream($context->{streams}{equal}, $cursor) };
    if (@equal_prices) {
        $out{"tf${tf}_eqh_eql_dist_pips"} =
            _signed_pips(_nearest_price(\@equal_prices, $reference_price),
                $reference_price, $self->{pip_size});
    }

    my $resolved_price = _nearest_event_price(
        _advance_stream($context->{streams}{resolved}, $cursor),
        $cursor, $reference_price, 'price', 'resolved_at',
    );
    $out{"tf${tf}_sweep_grab_run_dist_pips"} =
        _signed_pips($resolved_price, $reference_price, $self->{pip_size})
        if defined $resolved_price;

    my $sd = _nearest_zone(
        _advance_stream($context->{streams}{supply_demand}, $cursor),
        $cursor, $reference_price,
        sub { $_[0]{confirmed_at} }, sub { $_[0]{end_index} },
    );
    if ($sd) {
        $out{"tf${tf}_supply_demand_dist_pips"} =
            _signed_pips(($sd->{top} + $sd->{bottom}) / 2,
                $reference_price, $self->{pip_size});
        $out{"tf${tf}_supply_demand_width_pips"} =
            abs($sd->{top} - $sd->{bottom}) / $self->{pip_size};
    }

    my $channel = _nearest_channel(
        _advance_stream($context->{streams}{channel}, $cursor),
        $cursor, $reference_price,
    );
    if ($channel) {
        my $lower = $channel->{base_price}
            + $channel->{slope} * ($cursor - $channel->{base_index});
        my $upper = $lower + $channel->{width};
        my @boundaries = ($lower, $upper);
        $out{"tf${tf}_channel_dist_pips"} =
            _signed_pips(_nearest_price(\@boundaries, $reference_price),
                $reference_price, $self->{pip_size});
        $out{"tf${tf}_channel_width_pips"} =
            abs($channel->{width}) / $self->{pip_size};
    }
    return \%out;
}

sub _build_causal_channels {
    my ($self, $bars, $atr, $pivots) = @_;
    my @lows = sort { $a->{confirmed_at} <=> $b->{confirmed_at} }
        grep {
            (($_->{kind} // $_->{type} // '') eq 'low')
                && defined($_->{confirmed_at})
        } @$pivots;
    my (@atr_sum, @atr_count);
    my ($running_sum, $running_count) = (0, 0);
    for my $index (0 .. $#$atr) {
        if (defined($atr->[$index]) && $atr->[$index] > 0) {
            $running_sum += $atr->[$index];
            $running_count++;
        }
        ($atr_sum[$index], $atr_count[$index]) = ($running_sum, $running_count);
    }
    my @channels;
    for my $c_index (2 .. $#lows) {
        my $floor = max(0, $c_index - 30);
        my $found;
        my $a_attempts = 0;
        for (my $a_index = $c_index - 2; $a_index >= $floor; $a_index--) {
            my ($first, $last) = @lows[$a_index, $c_index];
            my $duration = $bars->[$last->{index}]{time} - $bars->[$first->{index}]{time};
            next if $duration < 2 * 60 * 60;
            last if ++$a_attempts > 3;
            my $slope = ($last->{price} - $first->{price})
                / ($last->{index} - $first->{index});
            my @middle = sort {
                my $expected_a = $first->{price}
                    + $slope * ($lows[$a]{index} - $first->{index});
                my $expected_b = $first->{price}
                    + $slope * ($lows[$b]{index} - $first->{index});
                abs($lows[$a]{price} - $expected_a)
                    <=> abs($lows[$b]{price} - $expected_b)
            } grep {
                my $price = $lows[$_]{price};
                ($first->{price} < $last->{price}
                    ? $price > $first->{price} && $price < $last->{price}
                    : $price < $first->{price} && $price > $last->{price})
            } ($a_index + 1 .. $c_index - 1);
            next unless @middle;
            my $channel = $self->_channel_from_three_lows(
                $bars, $atr, \@atr_sum, \@atr_count,
                $first, $lows[$middle[0]], $last,
            );
            if ($channel) {
                push @channels, $channel;
                $found = 1;
                last;
            }
        }
    }
    return \@channels;
}

sub _channel_from_three_lows {
    my ($self, $bars, $atr, $atr_sum, $atr_count, $a, $b, $c) = @_;
    return unless $a->{index} < $b->{index} && $b->{index} < $c->{index};
    my $duration = $bars->[$c->{index}]{time} - $bars->[$a->{index}]{time};
    return if $duration < 2 * 60 * 60;
    my $ascending = $a->{price} < $b->{price} && $b->{price} < $c->{price};
    my $descending = $a->{price} > $b->{price} && $b->{price} > $c->{price};
    return unless $ascending || $descending;

    my $slope = ($c->{price} - $a->{price}) / ($c->{index} - $a->{index});
    my $expected_b = $a->{price} + $slope * ($b->{index} - $a->{index});
    my $before = $a->{index} - 1;
    my $atr_total = $atr_sum->[ $c->{confirmed_at} ]
        - ($before >= 0 ? $atr_sum->[$before] : 0);
    my $atr_n = $atr_count->[ $c->{confirmed_at} ]
        - ($before >= 0 ? $atr_count->[$before] : 0);
    return unless $atr_n;
    my $mean_atr = $atr_total / $atr_n;
    return if abs($b->{price} - $expected_b) > 0.25 * $mean_atr;
    my $mean_price = ($a->{price} + $b->{price} + $c->{price}) / 3;
    return if $mean_price == 0
        || $mean_atr / abs($mean_price) > $self->{channel_atr_price_max};

    my @offsets;
    for my $index ($a->{index} .. $c->{confirmed_at}) {
        my $base = $a->{price} + $slope * ($index - $a->{index});
        push @offsets, $bars->[$index]{high} - $base;
    }
    my $width = max(@offsets);
    return unless defined($width) && $width > 0.75 * $mean_atr
        && $width < 8 * $mean_atr;

    my ($inside, $count) = (0, 0);
    for my $index ($a->{index} .. $c->{confirmed_at}) {
        my $base = $a->{price} + $slope * ($index - $a->{index});
        my $tolerance = 0.25 * ($atr->[$index] // $mean_atr);
        $inside++ if $bars->[$index]{low} >= $base - $tolerance
            && $bars->[$index]{high} <= $base + $width + $tolerance;
        $count++;
    }
    return if !$count || $inside / $count < 0.85;

    my $confirmed_at = $c->{confirmed_at};
    my $break_at;
    for my $index ($confirmed_at + 1 .. $#$bars) {
        my $base = $a->{price} + $slope * ($index - $a->{index});
        my $tolerance = 0.25 * ($atr->[$index] // $mean_atr);
        if ($bars->[$index]{close} < $base - $tolerance
            || $bars->[$index]{close} > $base + $width + $tolerance) {
            $break_at = $index;
            last;
        }
    }
    return {
        base_index => $a->{index}, base_price => $a->{price} + 0,
        slope => $slope + 0, width => $width + 0,
        confirmed_at => $confirmed_at, break_at => $break_at,
        anchors => [ map { $_->{index} } ($a, $b, $c) ],
        duration_minutes => $duration / 60,
        low_atr => 1, replay_safe => 1,
    };
}

sub _event_upper_bound {
    my ($events, $start, $limit) = @_;
    my ($low, $high) = ($start, scalar @$events);
    while ($low < $high) {
        my $middle = int(($low + $high) / 2);
        my $timestamp = $events->[$middle]{event_timestamp}
            // $events->[$middle]{_event_time};
        if (defined($timestamp) && $timestamp <= $limit) {
            $low = $middle + 1;
        }
        else {
            $high = $middle;
        }
    }
    return $low;
}

sub _ghost_event {
    my ($events, $event_index, $active, $relocation) = @_;
    my $serial = scalar @$events;
    return {
        event_id => join('_', 'ghost_relocated', $active->{type},
            $event_index, $active->{index}, $serial),
        event_index => $event_index,
        ghost_index => $active->{index},
        ghost_price => $active->{price} + 0,
        ghost_type  => $active->{type},
        relocation  => $relocation,
    };
}

sub _extreme_between {
    my ($bars, $start, $end, $type) = @_;
    $start = 0 if $start < 0;
    return if $start > $end || $end > $#$bars;
    my ($best_index, $best_price);
    for my $i ($start .. $end) {
        my $price = $bars->[$i]{$type};
        if (!defined($best_price)
            || ($type eq 'high' ? $price > $best_price : $price < $best_price)) {
            ($best_index, $best_price) = ($i, $price);
        }
    }
    return ($best_index, $best_price);
}

sub _compute_atr {
    my ($bars, $period) = @_;
    my @atr = (undef) x @$bars;
    return \@atr unless @$bars;
    my @tr;
    for my $i (0 .. $#$bars) {
        my $value = $bars->[$i]{high} - $bars->[$i]{low};
        if ($i) {
            $value = max(
                $value,
                abs($bars->[$i]{high} - $bars->[$i - 1]{close}),
                abs($bars->[$i]{low} - $bars->[$i - 1]{close}),
            );
        }
        $tr[$i] = $value;
        if ($i == $period - 1) {
            $atr[$i] = sum(@tr[0 .. $i]) / $period;
        }
        elsif ($i >= $period) {
            $atr[$i] = ($atr[$i - 1] * ($period - 1) + $value) / $period;
        }
    }
    return \@atr;
}

sub _compute_ema {
    my ($values, $period) = @_;
    my @ema = (undef) x @$values;
    return \@ema unless @$values;
    my $alpha = 2 / ($period + 1);
    my $running = $values->[0] + 0;
    $ema[0] = $running;
    for my $i (1 .. $#$values) {
        $running = $alpha * $values->[$i] + (1 - $alpha) * $running;
        $ema[$i] = $running;
    }
    return \@ema;
}

sub _aggregate_bars {
    my ($bars, $minutes) = @_;
    my $seconds = $minutes * 60;
    my (@out, $current, $current_bucket);
    for my $source (@$bars) {
        my $offset = $source->{timezone_offset} // 0;
        my $bucket = floor(($source->{time} + $offset) / $seconds) * $seconds - $offset;
        if (!defined($current_bucket) || $bucket != $current_bucket) {
            push @out, $current if $current;
            $current_bucket = $bucket;
            $current = {
                time => $bucket, end_time => $bucket + $seconds,
                open => $source->{open}, high => $source->{high},
                low => $source->{low}, close => $source->{close},
                volume => $source->{volume}, timezone_offset => $offset,
                source_start_index => $source->{source_index},
                source_end_index   => $source->{source_index},
            };
        }
        else {
            $current->{high} = $source->{high} if $source->{high} > $current->{high};
            $current->{low}  = $source->{low}  if $source->{low}  < $current->{low};
            $current->{close} = $source->{close};
            $current->{volume} += $source->{volume};
            $current->{source_end_index} = $source->{source_index};
        }
    }
    push @out, $current if $current;
    return \@out;
}

sub _last_closed_index {
    my ($bars, $event_time) = @_;
    my ($low, $high) = (0, $#$bars);
    my $answer = -1;
    while ($low <= $high) {
        my $middle = int(($low + $high) / 2);
        my $end = $bars->[$middle]{end_time} // ($bars->[$middle]{time} + 60);
        if ($end <= $event_time) {
            $answer = $middle;
            $low = $middle + 1;
        }
        else {
            $high = $middle - 1;
        }
    }
    return $answer;
}

sub _weighted_prefix {
    my ($bars) = @_;
    my (@weight, @sum_price, @sum_square);
    my ($w, $p, $p2) = (0, 0, 0);
    for my $i (0 .. $#$bars) {
        my $typical = ($bars->[$i]{high} + $bars->[$i]{low} + $bars->[$i]{close}) / 3;
        my $volume = $bars->[$i]{volume};
        $w  += $volume;
        $p  += $volume * $typical;
        $p2 += $volume * $typical * $typical;
        ($weight[$i], $sum_price[$i], $sum_square[$i]) = ($w, $p, $p2);
    }
    return { weight => \@weight, price => \@sum_price, square => \@sum_square };
}

sub _anchored_vwap {
    my ($prefix, $start, $end) = @_;
    return if $start < 0 || $end < $start;
    my $before = $start - 1;
    my $weight = $prefix->{weight}[$end] - ($before >= 0 ? $prefix->{weight}[$before] : 0);
    return if !$weight || $weight <= 0;
    my $price = $prefix->{price}[$end] - ($before >= 0 ? $prefix->{price}[$before] : 0);
    my $square = $prefix->{square}[$end] - ($before >= 0 ? $prefix->{square}[$before] : 0);
    my $mean = $price / $weight;
    my $variance = $square / $weight - $mean * $mean;
    $variance = 0 if $variance < 0 && $variance > -1e-9;
    return ($mean, $variance > 0 ? sqrt($variance) : 0);
}

sub _volume_profile {
    my ($context, $start, $end, $bins_count) = @_;
    return if $start < 0 || $end < $start || $end > $#{ $context->{bars} };
    my $key = "$start:$end:$bins_count";
    return $context->{profile_cache}{$key}
        if exists $context->{profile_cache}{$key};
    my $bars = $context->{bars};
    my $low = min(map { $bars->[$_]{low} } $start .. $end);
    my $high = max(map { $bars->[$_]{high} } $start .. $end);
    return if !defined($low) || !defined($high);
    if ($high <= $low) {
        return $context->{profile_cache}{$key} = {
            poc => $low, vah => $high, val => $low,
        };
    }
    my $step = ($high - $low) / $bins_count;
    my @volume = (0) x $bins_count;
    my $total = 0;
    for my $i ($start .. $end) {
        my $bar = $bars->[$i];
        my $range = $bar->{high} - $bar->{low};
        if ($range <= 0) {
            my $bin = int(($bar->{low} - $low) / $step);
            $bin = $bins_count - 1 if $bin >= $bins_count;
            $bin = 0 if $bin < 0;
            $volume[$bin] += $bar->{volume};
            $total += $bar->{volume};
            next;
        }
        my $first = max(0, int(($bar->{low} - $low) / $step));
        my $last  = min($bins_count - 1, int(($bar->{high} - $low) / $step));
        for my $bin ($first .. $last) {
            my $bin_low = $low + $bin * $step;
            my $bin_high = $bin_low + $step;
            my $overlap = min($bar->{high}, $bin_high) - max($bar->{low}, $bin_low);
            next if $overlap <= 0;
            $volume[$bin] += $bar->{volume} * $overlap / $range;
        }
        $total += $bar->{volume};
    }
    return if $total <= 0;
    my $poc_bin = 0;
    for my $bin (1 .. $#volume) {
        $poc_bin = $bin if $volume[$bin] > $volume[$poc_bin];
    }
    my ($lo_bin, $hi_bin, $area) = ($poc_bin, $poc_bin, $volume[$poc_bin]);
    while ($area < 0.70 * $total && ($lo_bin > 0 || $hi_bin < $#volume)) {
        my $left = $lo_bin > 0 ? $volume[$lo_bin - 1] : -1;
        my $right = $hi_bin < $#volume ? $volume[$hi_bin + 1] : -1;
        if ($right >= $left) {
            $hi_bin++;
            $area += $volume[$hi_bin];
        }
        else {
            $lo_bin--;
            $area += $volume[$lo_bin];
        }
    }
    return $context->{profile_cache}{$key} = {
        poc => $low + ($poc_bin + 0.5) * $step,
        vah => $low + ($hi_bin + 1) * $step,
        val => $low + $lo_bin * $step,
    };
}

sub _causal_supply_demand {
    my ($zones, $bars) = @_;
    my @out;
    for my $zone (@$zones) {
        my $index = $zone->{index};
        my $confirmed = $zone->{confirmed_at} // $zone->{triggered_by} // $index;
        next unless defined($index) && defined($confirmed)
            && $index >= 0 && $confirmed <= $#$bars;
        my $start = max(0, $confirmed - 99);
        my @past = sort { $a <=> $b } map { $bars->[$_]{volume} } $start .. $confirmed;
        next unless @past;
        my $threshold = $past[int(0.70 * $#past + 0.5)];
        next if ($bars->[$index]{volume} // 0) < $threshold;
        push @out, {
            %$zone, confirmed_at => $confirmed,
            source => 'diy_causal_volume_order_block', replay_safe => 1,
        };
    }
    return \@out;
}

sub _make_stream {
    my ($items, $available_cb, $expires_cb, $lookback) = @_;
    my @sorted = sort {
        ($available_cb->($a) // 9_999_999_999)
            <=> ($available_cb->($b) // 9_999_999_999)
    } grep { defined $available_cb->($_) } @$items;
    return {
        items => \@sorted, pointer => 0, active => [],
        available_cb => $available_cb, expires_cb => $expires_cb,
        lookback => $lookback, cursor => -1,
    };
}

sub _advance_stream {
    my ($stream, $cursor) = @_;
    die 'GhostFeatureExtractor: los snapshots deben consultarse en orden temporal'
        if $cursor < ($stream->{cursor} // -1);
    my $items = $stream->{items};
    while ($stream->{pointer} < @$items) {
        my $item = $items->[ $stream->{pointer} ];
        my $available = $stream->{available_cb}->($item);
        last if $available > $cursor;
        push @{ $stream->{active} }, $item;
        $stream->{pointer}++;
    }
    my $expires_cb = $stream->{expires_cb};
    my $floor = defined($stream->{lookback})
        ? $cursor - $stream->{lookback} : undef;
    if ($expires_cb || defined $floor) {
        @{ $stream->{active} } = grep {
            my $expires = $expires_cb ? $expires_cb->($_) : undef;
            my $available = $stream->{available_cb}->($_);
            (!defined($expires) || $expires > $cursor)
                && (!defined($floor) || $available >= $floor)
        } @{ $stream->{active} };
    }
    $stream->{cursor} = $cursor;
    return $stream->{active};
}

sub _nearest_zone {
    my ($zones, $cursor, $reference, $confirmed_cb, $end_cb) = @_;
    my ($best, $distance);
    for my $zone (@$zones) {
        next unless defined($zone->{top}) && defined($zone->{bottom});
        my $confirmed = $confirmed_cb->($zone);
        next unless defined($confirmed) && $confirmed <= $cursor;
        my $end = $end_cb->($zone);
        next if defined($end) && $end <= $cursor;
        my $mid = ($zone->{top} + $zone->{bottom}) / 2;
        my $candidate = abs($mid - $reference);
        my $best_confirmed = $best ? ($confirmed_cb->($best) // -1) : -1;
        if (!defined($distance) || $candidate < $distance
            || ($candidate == $distance && $confirmed > $best_confirmed)) {
            ($best, $distance) = ($zone, $candidate);
        }
    }
    return $best;
}

sub _nearest_event_price {
    my ($events, $cursor, $reference, $price_field, $confirmed_field) = @_;
    my (@prices, $recent_floor);
    $recent_floor = max(0, $cursor - 500);
    for my $event (@$events) {
        my $confirmed = $event->{$confirmed_field} // $event->{index};
        next unless defined($confirmed)
            && $confirmed <= $cursor && $confirmed >= $recent_floor;
        push @prices, $event->{$price_field}
            if defined $event->{$price_field};
    }
    return @prices ? _nearest_price(\@prices, $reference) : undef;
}

sub _nearest_channel {
    my ($channels, $cursor, $reference) = @_;
    my ($best, $best_distance);
    for my $channel (@$channels) {
        next if $channel->{confirmed_at} > $cursor;
        next if defined($channel->{break_at}) && $channel->{break_at} <= $cursor;
        my $lower = $channel->{base_price}
            + $channel->{slope} * ($cursor - $channel->{base_index});
        my $upper = $lower + $channel->{width};
        my $distance = min(abs($lower - $reference), abs($upper - $reference));
        if (!defined($best_distance) || $distance < $best_distance) {
            ($best, $best_distance) = ($channel, $distance);
        }
    }
    return $best;
}

sub _last_alternating_pivots {
    my ($pivots) = @_;
    return unless @$pivots >= 2;
    my $last = $pivots->[-1];
    my $last_type = $last->{kind} // $last->{type};
    for (my $i = $#$pivots - 1; $i >= 0; $i--) {
        my $type = $pivots->[$i]{kind} // $pivots->[$i]{type};
        return ($last, $pivots->[$i]) if defined($type) && $type ne $last_type;
    }
    return;
}

sub _nearest_price {
    my ($prices, $reference) = @_;
    my ($best, $distance);
    for my $price (@$prices) {
        next unless defined $price;
        my $candidate = abs($price - $reference);
        if (!defined($distance) || $candidate < $distance
            || ($candidate == $distance && (!defined($best) || $price > $best))) {
            ($best, $distance) = ($price, $candidate);
        }
    }
    return $best;
}

sub _signed_pips {
    my ($level, $reference, $pip) = @_;
    return undef unless defined($level) && defined($reference);
    return ($level - $reference) / $pip;
}

sub _prepare_support_resistance {
    my ($bars) = @_;
    my %result;
    for my $entry ([240, '4h'], [1440, 'd'], [10080, 'w']) {
        my ($minutes, $name) = @$entry;
        my $seconds = $minutes * 60;
        my (%groups, @order);
        for my $bar (@$bars) {
            my $offset = $bar->{timezone_offset} // 0;
            my $local = $bar->{time} + $offset;
            my $key;
            if ($name eq 'w') {
                my $day = floor($local / 86_400);
                my $monday = $day - (($day + 3) % 7);
                $key = $monday;
            }
            else {
                $key = floor($local / $seconds);
            }
            if (!exists $groups{$key}) {
                $groups{$key} = { high => $bar->{high}, low => $bar->{low} };
                push @order, $key;
            }
            else {
                $groups{$key}{high} = $bar->{high} if $bar->{high} > $groups{$key}{high};
                $groups{$key}{low} = $bar->{low} if $bar->{low} < $groups{$key}{low};
            }
        }
        my %previous;
        for my $i (1 .. $#order) {
            $previous{$order[$i]} = $groups{$order[$i - 1]};
        }
        $result{$name} = {
            seconds => $seconds, groups => \%groups, previous => \%previous,
        };
    }
    return \%result;
}

sub _support_resistance_at {
    my ($prepared, $event_time, $offset, $reference, $pip) = @_;
    my %out;
    for my $name (qw(4h d w)) {
        my $entry = $prepared->{$name};
        my $local = $event_time + ($offset // 0);
        my $key;
        if ($name eq 'w') {
            my $day = floor($local / 86_400);
            $key = $day - (($day + 3) % 7);
        }
        else {
            $key = floor($local / $entry->{seconds});
        }
        my $previous = $entry->{previous}{$key};
        my $column = $name eq '4h' ? 'sr_4h_dist_pips'
            : $name eq 'd' ? 'sr_d_dist_pips' : 'sr_w_dist_pips';
        if ($previous) {
            my @prices = ($previous->{high}, $previous->{low});
            $out{$column} = _signed_pips(
                _nearest_price(\@prices, $reference), $reference, $pip,
            );
        }
        else {
            $out{$column} = undef;
        }
    }
    return \%out;
}

sub _parse_timestamp {
    my ($timestamp) = @_;
    return unless defined($timestamp) && $timestamp =~
        /^(\d{4})-(\d{2})-(\d{2})[T ](\d{2}):(\d{2}):(\d{2})(Z|([+-])(\d{2}):?(\d{2}))$/;
    my ($year, $month, $day, $hour, $minute, $second) =
        ($1, $2, $3, $4, $5, $6);
    my $zone = $7;
    my $offset = 0;
    if ($zone ne 'Z') {
        $offset = ($9 * 3600 + $10 * 60) * ($8 eq '+' ? 1 : -1);
    }
    my $nominal;
    eval {
        $nominal = timegm($second, $minute, $hour, $day, $month - 1, $year);
    };
    return if $@ || !defined $nominal;
    my $epoch = $nominal - $offset;
    return ($epoch, $offset, sprintf('%04d-%02d-%02d', $year, $month, $day),
        int($hour), int($minute));
}

sub _csv_value {
    my ($value) = @_;
    return '' unless defined $value;
    if (!ref($value) && _finite($value)) {
        return sprintf('%.10g', $value + 0);
    }
    my $text = "$value";
    if ($text =~ /[",\r\n]/) {
        $text =~ s/"/""/g;
        return qq{"$text"};
    }
    return $text;
}

sub _finite {
    my ($value) = @_;
    return defined($value) && !ref($value)
        && "$value" =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/
        && $value == $value && abs($value) <= 1e300;
}

1;
