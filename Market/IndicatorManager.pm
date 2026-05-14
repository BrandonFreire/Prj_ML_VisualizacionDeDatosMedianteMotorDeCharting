package Market::IndicatorManager;

use strict;
use warnings;

sub new {
    my ($class) = @_;
    my $self = {
        indicators => {},
    };
    bless $self, $class;
    return $self;
}

sub register {
    my ($self, $name, $indicator) = @_;
    $self->{indicators}{$name} = $indicator;
}

sub update_last {
    my ($self, $market_data) = @_;
    for my $ind ( values %{ $self->{indicators} } ) {
        $ind->update_last($market_data);
    }
}

sub get {
    my ($self, $name) = @_;
    return $self->{indicators}{$name};
}

sub slice_array {
    my ($self, $name, $start, $end) = @_;
    my $ind = $self->{indicators}{$name};
    return [] unless $ind;
    my $values = $ind->get_values();
    my $size   = scalar @$values;
    $start = 0        if $start < 0;
    $end   = $size - 1 if $end >= $size;
    return [] if $start > $end;
    return [ @{$values}[ $start .. $end ] ];
}

sub reset_all {
    my ($self) = @_;
    for my $ind ( values %{ $self->{indicators} } ) {
        $ind->reset();
    }
}

1;
