package Market::ML::GhostTargets;

use strict;
use warnings;

# Etiquetado retrospectivo para entrenamiento.  Replay consume solamente
# GhostsInSwings; este módulo deliberadamente mira el futuro para construir Y.
my @WINDOWS = (3, 5, 10, 15);

sub new { return bless { _records => [] }, shift }

sub compute {
    my ($class_or_self, %args) = @_;
    my $self = ref($class_or_self) ? $class_or_self : $class_or_self->new;
    my $relocations = $args{relocations} // [];
    my $trails = $args{trails} // [];
    die 'GhostTargets::compute: relocations debe ser un arrayref'
        unless ref($relocations) eq 'ARRAY';
    die 'GhostTargets::compute: trails debe ser un arrayref'
        unless ref($trails) eq 'ARRAY';
    my $last = defined($args{last_index}) ? $args{last_index} : _last_index($relocations, $trails);
    die 'GhostTargets::compute: last_index debe ser un entero no negativo'
        unless defined($last) && $last =~ /^\d+$/;

    my @ordered_trails = sort {
        ($a->{occurrence_index} // -1) <=> ($b->{occurrence_index} // -1)
    } grep { defined($_->{occurrence_index}) && $_->{occurrence_index} =~ /^\d+$/ } @$trails;
    my @records;
    for my $event (sort { ($a->{occurrence_index} // -1) <=> ($b->{occurrence_index} // -1) } @$relocations) {
        next unless defined($event->{occurrence_index}) && $event->{occurrence_index} =~ /^\d+$/;
        my $start = int($event->{occurrence_index});
        my %record = (
            event_id => $event->{id}, event_index => $start,
            event_timestamp => $event->{occurrence_time},
            ghost_index => $event->{ghost_index}, ghost_timestamp => $event->{ghost_time},
            ghost_price => $event->{price}, ghost_type => $event->{type},
            relocation => $event->{relocation},
        );
        my $complete = 1;
        for my $minutes (@WINDOWS) {
            my $key = "Y_${minutes}m";
            if ($start + $minutes > $last) {
                $record{$key} = undef;
                $record{"complete_${minutes}m"} = 0;
                $complete = 0;
                next;
            }
            $record{$key} = scalar grep {
                $_->{occurrence_index} > $start && $_->{occurrence_index} <= $start + $minutes
            } @ordered_trails;
            $record{"complete_${minutes}m"} = 1;
        }
        $record{complete} = $complete ? 1 : 0;
        push @records, \%record;
    }
    $self->{_records} = \@records;
    return [ map { { %$_ } } @records ];
}

sub compute_from_indicator {
    my ($self, $indicator, %args) = @_;
    die 'GhostTargets::compute_from_indicator: indicador invalido'
        unless $indicator && $indicator->can('get_relocations') && $indicator->can('get_trails');
    $args{relocations} = $indicator->get_relocations;
    $args{trails} = $indicator->get_trails;
    $args{last_index} //= $indicator->can('get_max_index')
        ? $indicator->get_max_index : undef;
    return $self->compute(%args);
}

sub get_records { return [ map { { %$_ } } @{ $_[0]->{_records} // [] } ] }

sub _last_index {
    my (@sets) = @_;
    my $last = 0;
    for my $set (@sets) {
        for my $event (@$set) {
            my $i = $event->{occurrence_index};
            $last = $i if defined($i) && $i =~ /^\d+$/ && $i > $last;
        }
    }
    return $last;
}

1;
