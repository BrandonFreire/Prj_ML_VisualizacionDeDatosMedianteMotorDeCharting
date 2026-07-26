package Market::ML::RawCsv;

use strict;
use warnings;

# Lector deliberadamente pequeño y sin dependencia CPAN para CSV OHLCV. Acepta
# comillas RFC-4180, cabecera sin distinción de mayúsculas y timestamps ISO-8601
# con offset, como los archivos exportados por la plataforma.

sub load_ohlcv_1m {
    my ($class, %args) = @_;
    my $path = $args{path} // $args{input};
    die 'RawCsv::load_ohlcv_1m: path requerido' unless defined($path) && length($path);
    open my $fh, '<', $path or die "No se pudo abrir $path: $!";

    my $header_line = <$fh>;
    die "$path: falta cabecera CSV" unless defined $header_line;
    $header_line =~ s/^\x{EF}\x{BB}\x{BF}//;
    my @header = map { lc _trim($_) } _parse_csv_line($header_line);
    my %column;
    $column{ $header[$_] } = $_ for 0 .. $#header;
    my %required = (
        time => 'time', open => 'open', high => 'high', low => 'low', close => 'close',
    );
    $required{volume} = exists($column{volume}) ? 'volume' : 'Volume';
    for my $name (qw(time open high low close)) {
        die "$path: falta columna $name" unless exists $column{$required{$name}};
    }
    # Se normalizó la cabecera a minúsculas, por ello Volume y volume son la
    # misma columna. Mantener esta comprobación separada da un error útil.
    die "$path: falta columna volume" unless exists $column{volume};

    my @candles;
    my $previous_time;
    my $line_no = 1;
    while (my $line = <$fh>) {
        ++$line_no;
        next if $line =~ /^\s*$/;
        my @values = _parse_csv_line($line);
        my %row;
        for my $name (qw(time open high low close volume)) {
            my $index = $column{$name};
            $row{$name} = defined($index) ? _trim($values[$index]) : undef;
        }
        my $time = parse_iso8601_epoch($row{time});
        die "$path:$line_no timestamp ISO-8601 inválido" unless defined $time;
        for my $field (qw(open high low close volume)) {
            die "$path:$line_no $field no es numérico finito"
                unless _finite($row{$field});
            $row{$field} += 0;
        }
        die "$path:$line_no high menor que low" if $row{high} < $row{low};
        die "$path:$line_no open fuera de high/low"
            if $row{open} < $row{low} || $row{open} > $row{high};
        die "$path:$line_no close fuera de high/low"
            if $row{close} < $row{low} || $row{close} > $row{high};
        die "$path:$line_no volumen negativo" if $row{volume} < 0;
        die "$path:$line_no no está ordenado cronológicamente o contiene duplicado"
            if defined($previous_time) && $time <= $previous_time;
        if ($args{require_contiguous} && defined($previous_time) && $time != $previous_time + 60) {
            die "$path:$line_no hueco 1m entre $previous_time y $time";
        }
        my %candle = (time => $time);
        $candle{$_} = $row{$_} for qw(open high low close volume);
        push @candles, \%candle;
        $previous_time = $time;
    }
    close $fh or die "No se pudo cerrar $path: $!";
    return \@candles;
}

sub parse_iso8601_epoch {
    my ($ts) = @_;
    return undef unless defined $ts;
    $ts = _trim($ts);
    return undef unless $ts =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d+)?(?:Z|([-+])(\d{2}):(\d{2}))$/;
    my ($year, $month, $day, $hour, $minute, $second, $sign, $offset_h, $offset_m) =
        ($1, $2, $3, $4, $5, $6, $7, $8, $9);
    return undef if $month < 1 || $month > 12 || $day < 1 || $day > _days_in_month($year, $month)
        || $hour > 23 || $minute > 59 || $second > 59;
    my @month_days = (0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334);
    my $leap = _is_leap($year);
    my $doy = $month_days[$month - 1] + ($month > 2 && $leap ? 1 : 0) + $day;
    my $days = ($year - 1970) * 365 + int(($year - 1969) / 4)
        - int(($year - 1901) / 100) + int(($year - 1601) / 400) + $doy - 1;
    my $epoch = $days * 86_400 + $hour * 3_600 + $minute * 60 + $second;
    return $epoch unless defined $sign; # Z
    return undef if $offset_h > 23 || $offset_m > 59;
    my $offset = $offset_h * 3_600 + $offset_m * 60;
    return $epoch - ($sign eq '+' ? $offset : -$offset);
}

sub _parse_csv_line {
    my ($line) = @_;
    chomp $line;
    $line =~ s/\r$//;
    my (@out, $field, $quoted) = ((), '', 0);
    my @chars = split //, $line;
    for (my $i = 0; $i <= $#chars; ++$i) {
        my $ch = $chars[$i];
        if ($quoted) {
            if ($ch eq '"' && $i < $#chars && $chars[$i + 1] eq '"') { $field .= '"'; ++$i; }
            elsif ($ch eq '"') { $quoted = 0; }
            else { $field .= $ch; }
        } elsif ($ch eq '"') {
            die 'CSV con comilla inesperada' if length($field);
            $quoted = 1;
        } elsif ($ch eq ',') {
            push @out, $field; $field = '';
        } else { $field .= $ch; }
    }
    die 'CSV con comilla sin cerrar' if $quoted;
    push @out, $field;
    return @out;
}

sub _trim { my ($v) = @_; $v //= ''; $v =~ s/^\s+|\s+$//g; return $v }
sub _is_leap { return $_[0] % 4 == 0 && ($_[0] % 100 != 0 || $_[0] % 400 == 0) }
sub _days_in_month {
    my ($year, $month) = @_;
    my @days = (0, 31, _is_leap($year) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31);
    return $days[$month];
}
sub _finite {
    return defined($_[0]) && !ref($_[0]) && "$_[0]" =~ /^[-+]?(?:\d+(?:\.\d*)?|\.\d+)(?:[eE][-+]?\d+)?$/
        && $_[0] == $_[0] && abs($_[0]) <= 1e300;
}

1;
