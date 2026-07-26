use strict;
use warnings;

use Test::More;
use File::Temp qw(tempfile);
use lib '.';

use Market::ML::GhostLSTMExtractor;

sub candle {
    my ($i) = @_;
    my $close = 1.1000 + $i * 0.0001;
    return {
        time => $i * 60, open => $close - 0.00005, high => $close + 0.00015,
        low => $close - 0.00015, close => $close, volume => 100 + $i,
    };
}

my $candles = [ map { candle($_) } 0 .. 40 ];
my $extractor = Market::ML::GhostLSTMExtractor->new(pip_size => 0.0001, pivot_length => 2);
my @visible;
my @replay_steps;
my ($fh, $path) = tempfile();
close $fh;

my $result = $extractor->export_csv(
    candles_1m => $candles,
    output_csv => $path,
    # Un detector inyectado hace este test independiente de la geometría de
    # pivotes; el módulo sigue usando confirmed_at como trigger causal.
    ghost_detector => sub {
        return { missed_pivots => [
            { id => 'g10', type => 'high', price => 1.1010, confirmed_at => 10 },
            { id => 'g20', type => 'low',  price => 1.1020, confirmed_at => 20 },
        ] };
    },
    # Reproduce explícitamente un rastro consolidado a +10m para aislar el
    # test del detector de pivotes regular usado por el modo por defecto.
    trace_events => [ { time => 21 * 60 } ],
    replay_step => sub { push @replay_steps, $_[0]{visible_index} },
    level_snapshot => sub {
        my ($ctx) = @_;
        push @visible, [ $ctx->{timeframe}, $ctx->{visible_index} ];
        return {
            replay_safe => 1,
            order_block => [ { level => 1.1020, range_low => 1.1015, range_high => 1.1025 } ],
            volume_profile => [ { level => 1.1018, range_low => 1.1010, range_high => 1.1026 } ],
        };
    },
);

is($result->{rows_written}, 2, 'exporta una fila por aparición confirmada del fantasma');
is(scalar @replay_steps, scalar @$candles, 'avanza el Replay de datos vela por vela');
is($result->{skipped_incomplete_target}, 0, 'las dos filas cuentan con futuro completo de 15m');
ok((grep { $_->[0] eq '10m' && $_->[1] >= 0 } @visible),
    'la foto de 10m contiene únicamente velas HTF ya cerradas');
ok((grep { $_->[0] eq '1h' && $_->[1] == -1 } @visible),
    'la foto de 1h no inventa una vela aún abierta');

open my $read, '<', $path or die $!;
my @lines = <$read>;
close $read;
is(scalar @lines, 3, 'escribe cabecera una vez y dos datos');
like($lines[0], qr/1m_order_block_dist_level_pips/, 'la cabecera incluye distancias por temporalidad');
like($lines[0], qr/target_rastro_next_15m/, 'la cabecera incluye los cuatro targets');

# CSV propio entrecomilla todos los valores; las últimas cuatro columnas son Y.
my @first = $lines[1] =~ /"([^"]*)"/g;
is_deeply([ @first[-4 .. -1] ], [ 0, 0, 1, 1 ],
    'el evento a +10m se cuenta exactamente en las ventanas de 10m y 15m');

done_testing();
