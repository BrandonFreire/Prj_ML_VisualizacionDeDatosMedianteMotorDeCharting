#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use lib "$Bin/..";
use Getopt::Long qw(GetOptions);

use Market::ML::RawCsv;
use Market::ML::GhostLSTMExtractor;

# Ejemplo:
# perl bin/extract_ghost_lstm.pl \
#   --input 2026_Abril-Junio.csv --output ghost_lstm.csv \
#   --pip-size 0.25 --level-provider My::InstitutionalLevels
#
# El provider no es un overlay Tk. Debe implementar:
#   My::InstitutionalLevels->new(candles_1m => \@candles, ...)
#   $provider->snapshot($replay_context) -> { replay_safe => 1, ...11 grupos }
# El contrato completo de los once grupos se documenta en
# Market::ML::GhostLSTMExtractor.

my %opt = (
    input         => '2026_Abril-Junio.csv',
    output        => 'ghost_lstm_feature_matrix.csv',
    pivot_length  => 20,
    atr_period    => 14,
    volume_ema    => 9,
    require_contiguous => 0,
);
GetOptions(
    'input=s'              => \$opt{input},
    'output=s'             => \$opt{output},
    'pip-size=f'           => \$opt{pip_size},
    'pivot-length=i'       => \$opt{pivot_length},
    'atr-period=i'         => \$opt{atr_period},
    'volume-ema=i'         => \$opt{volume_ema},
    'level-provider=s'     => \$opt{level_provider},
    'require-contiguous!'  => \$opt{require_contiguous},
) or die "Argumentos inválidos. Use --input, --output y --level-provider.\n";
die "--pip-size debe ser positivo\n" unless defined($opt{pip_size}) && $opt{pip_size} > 0;
die "--level-provider es obligatorio: evita exportar niveles ficticios\n"
    unless defined($opt{level_provider}) && length($opt{level_provider});

my $candles = Market::ML::RawCsv->load_ohlcv_1m(
    path => $opt{input}, require_contiguous => $opt{require_contiguous},
);
die "El CSV no contiene velas\n" unless @$candles;

my $provider_class = $opt{level_provider};
eval "require $provider_class; 1" or die "No se pudo cargar $provider_class: $@";
die "$provider_class debe implementar new() y snapshot()"
    unless $provider_class->can('new') && $provider_class->can('snapshot');
my $provider = $provider_class->new(candles_1m => $candles);

my $extractor = Market::ML::GhostLSTMExtractor->new(
    pip_size       => $opt{pip_size},
    pivot_length   => $opt{pivot_length},
    atr_period     => $opt{atr_period},
    volume_ema_len => $opt{volume_ema},
);

my $result = $extractor->export_csv(
    candles_1m => $candles,
    output_csv => $opt{output},
    # Es el bucle de Replay de datos. Un provider incremental puede avanzar
    # aquí su estado; no se crea ningún canvas ni se altera la UI de Tk.
    replay_step => sub { $provider->replay_step($_[0]) if $provider->can('replay_step') },
    level_snapshot => sub { $provider->snapshot($_[0]) },
);

printf "CSV leído: %d velas  |  triggers: %d  |  filas escritas: %d  |  Y incompleto: %d\n",
    scalar(@$candles), $result->{trigger_count}, $result->{rows_written},
    $result->{skipped_incomplete_target};

