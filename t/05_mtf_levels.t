use strict;
use warnings;

use Test::More;
use Time::Local qw(timegm);
use lib '.';

use Market::MTFLevels;

sub epoch {
    my ($day, $hour, $minute) = @_;
    return timegm(0, $minute, $hour, $day, 6, 2026 - 1900);
}

my @candles = (
    # Lunes 6 de julio (09:00--11:00 hora -05:00)
    { time => epoch(6, 14, 0), high => 100, low => 90, close => 95 },
    { time => epoch(6, 15, 0), high => 110, low => 95, close => 106 },
    { time => epoch(6, 16, 0), high => 105, low => 92, close => 100 },
    # Martes 7 de julio
    { time => epoch(7, 14, 0), high => 115, low => 88, close => 110 },
    { time => epoch(7, 15, 0), high => 120, low => 85, close => 100 },
    { time => epoch(7, 16, 0), high => 118, low => 90, close => 105 },
    # Lunes siguiente: abre una nueva semana
    { time => epoch(13, 14, 0), high => 130, low => 80, close => 120 },
    { time => epoch(13, 15, 0), high => 125, low => 82, close => 110 },
);

my $levels = Market::MTFLevels->new(session_offset_seconds => -5 * 3600);

my $daily = $levels->previous_high_low_levels(
    candles => \@candles, reference_index => 5, periods => ['D'],
);
is(scalar @$daily, 2, 'genera PDH y PDL al entrar en un día nuevo');
my %daily = map { $_->{type} => $_ } @$daily;
is($daily{PDH}{price}, 110, 'PDH usa el máximo del día cerrado anterior');
is($daily{PDL}{price}, 90, 'PDL usa el mínimo del día cerrado anterior');
is($daily{PDH}{anchor_index}, 1, 'PDH conserva el índice del máximo real');
is($daily{PDH}{available_at}, 3, 'PDH solo está disponible desde la primera vela del día actual');

my $weekly = $levels->previous_high_low_levels(
    candles => \@candles, reference_index => 7, periods => ['W'],
);
is(scalar @$weekly, 2, 'genera PWH y PWL al entrar en una semana nueva');
my %weekly = map { $_->{type} => $_ } @$weekly;
is($weekly{PWH}{price}, 120, 'PWH excluye la semana actual abierta');
is($weekly{PWL}{price}, 85, 'PWL excluye la semana actual abierta');
is($weekly{PWH}{available_at}, 6, 'PWH aparece al inicio de la semana actual');

my $replay_daily = $levels->previous_high_low_levels(
    candles => \@candles, reference_index => 5, periods => ['D', 'W'],
);
is(scalar @$replay_daily, 2, 'el cursor de Replay ignora velas futuras y semanas posteriores');

done_testing();
