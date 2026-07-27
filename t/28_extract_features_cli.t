use strict;
use warnings;

use Test::More;
use File::Temp qw(tempdir);
use File::Spec;
use FindBin;

my $dir = tempdir(CLEANUP => 1);
my $input = File::Spec->catfile($dir, 'input.csv');
my $output = File::Spec->catfile($dir, 'features.csv');
open my $fh, '>', $input or die $!;
print {$fh} "time,open,high,low,close,Volume\n";
for my $i (0 .. 220) {
    # Máximo único en 50, seguido por mínimos descendentes: con length=50 se
    # confirma el pivote y aparecen reubicaciones suficientes para targets.
    my $high = $i <= 50 ? 100 + $i : 150 - ($i - 50) * 0.25;
    my $low  = $i <= 100 ? $high - 10 : $high - 10 - ($i - 100) * 0.10;
    my $open = ($high + $low) / 2;
    printf {$fh} "%d,%.4f,%.4f,%.4f,%.4f,%d\n", 1_700_000_000 + $i * 60,
        $open, $high, $low, $open, 100 + $i;
}
close $fh;

my $script = File::Spec->catfile($FindBin::Bin, '..', 'extract_features.pl');
is(system($^X, $script, '--input', $input, '--output', $output, '--pip-size', '0.01', '--quiet'), 0,
    'el extractor CLI se ejecuta sin interfaz Tk');
open my $out, '<', $output or die $!;
my $header = <$out> // '';
my $first = <$out> // '';
close $out;
like($header, qr/tf1_ob_dist_pips/, 'exporta niveles de Order Block de 1m');
like($header, qr/tf10_vwap_band2_dist_pips/, 'exporta VWAP/bandas en 10m');
like($header, qr/tf60_channel_width_pips/, 'exporta rango de canal en 1h');
like($header, qr/Y_3m,Y_5m,Y_10m,Y_15m,complete/, 'incluye todos los targets Y');
ok(length $first, 'genera al menos una fila de evento fantasma');

done_testing();
