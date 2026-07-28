#!/usr/bin/env perl

use strict;
use warnings;

use FindBin qw($Bin);
use Getopt::Long qw(GetOptions);
use lib "$Bin/..";

use Market::ML::GhostFeatureExtractor;

my $pip_size = 0.25;
my $ghost_length = 50;
my $include_incomplete = 0;
my $help = 0;

GetOptions(
    'pip-size=f'          => \$pip_size,
    'ghost-length=i'      => \$ghost_length,
    'include-incomplete!' => \$include_incomplete,
    'help'                => \$help,
) or usage(2);
usage(0) if $help;

my ($input_csv, $output_csv) = @ARGV;
usage(2) unless defined $input_csv && defined $output_csv && @ARGV == 2;

print "Extractor causal de caracteristicas Ghosts_in_swings\n";
print "Entrada: $input_csv\n";
print "Salida:  $output_csv\n";
print "PIP: $pip_size | pivote: $ghost_length | Replay base: 1 minuto\n";

my $extractor = Market::ML::GhostFeatureExtractor->new(
    pip_size     => $pip_size,
    ghost_length => $ghost_length,
);

print "Cargando y validando OHLCV...\n";
my $bars = $extractor->load_csv($input_csv);
print "  Velas de 1 minuto: ", scalar(@$bars), "\n";

print "Reproduciendo Replay y detectando apariciones/reubicaciones...\n";
my $result = $extractor->extract(
    bars => $bars,
    include_incomplete => $include_incomplete,
);
print "  Eventos detectados: ", scalar(@{ $result->{events} }), "\n";

print "Calculando los 11 grupos de niveles en 1m, 10m y 1h...\n";
my $written = $extractor->write_csv($output_csv, $result);
print "Listo: $written registros escritos.\n";
print "Features: ", scalar(@{ $result->{feature_columns} }),
    " (metadatos y 4 targets excluidos de este total)\n";
print "Targets: Y_3m, Y_5m, Y_10m, Y_15m; ventana abierta en t y cerrada en t+N.\n";
print "Filas incompletas incluidas: ", ($include_incomplete ? 'si' : 'no'), "\n";

sub usage {
    my ($status) = @_;
    my $stream = $status ? *STDERR : *STDOUT;
    print {$stream} <<"USAGE";
Uso:
  perl ml/extract_features.pl [opciones] ENTRADA.csv SALIDA.csv

Opciones:
  --pip-size N           Tamano de un PIP (predeterminado: 0.25 para NQ).
  --ghost-length N       Longitud del pivote Ghosts_in_swings (50).
  --include-incomplete   Conserva eventos de los ultimos 15 minutos con Y vacio.
  --help                 Muestra esta ayuda.
USAGE
    exit $status;
}
