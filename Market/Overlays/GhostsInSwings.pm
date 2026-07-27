package Market::Overlays::GhostsInSwings;

use strict;
use warnings;
use utf8;

sub new {
    my ($class, %args) = @_;
    return bless {
        indicator => $args{indicator}, visibility => $args{visibility},
        market => $args{market},
    }, $class;
}

sub _visible {
    my ($self, $key, $default) = @_;
    my $v = $self->{visibility};
    return $default unless $v && exists $v->{$key};
    return $v->{$key} ? 1 : 0;
}

sub _is_one_minute {
    my ($self) = @_;
    return 1 unless $self->{market};
    return ($self->{market}{current_tf} // '1') eq '1';
}

sub render {
    my ($self, $canvas, $d_start, $d_end, $scale, $current_bar) = @_;
    $canvas->delete('ghosts_overlay');
    return unless $self->_visible('ghosts_enabled', 1) && $self->_is_one_minute;
    my $ind = $self->{indicator};
    return unless $ind && $scale;
    $current_bar //= $d_end;

    if ($self->_visible('show_ghost_trails', 1)) {
        for my $trail (@{ $ind->get_trails // [] }) {
            next unless ($trail->{occurrence_index} // -1) <= $current_bar;
            my $index = $trail->{ghost_index};
            next unless defined($index) && $index >= $d_start && $index <= $d_end;
            my $x = $scale->index_to_center_x($index);
            my $y = $scale->value_to_y($trail->{price});
            my $color = ($trail->{type} // '') eq 'low' ? '#26a69a' : '#ef5350';
            $canvas->createText($x, $y, -text => '1', -fill => $color,
                -font => ['Helvetica', 9, 'bold'], -anchor => 'center',
                -tags => ['ghosts_overlay', 'ghosts_trail']);
        }
    }

    return unless $self->_visible('show_ghost_active', 1);
    my $ghost = $ind->get_active_ghost_at($current_bar);
    return unless $ghost && defined($ghost->{ghost_index}) && defined($ghost->{price});
    return unless $ghost->{ghost_index} >= $d_start && $ghost->{ghost_index} <= $d_end;
    my $x = $scale->index_to_center_x($ghost->{ghost_index});
    my $y = $scale->value_to_y($ghost->{price});
    my $type = $ghost->{type} // 'low';
    my $color = $type eq 'low' ? '#26a69a' : '#ef5350';
    $y += $type eq 'low' ? 14 : -14;
    $canvas->createText($x, $y, -text => "\x{1F47B}", -fill => $color,
        -font => ['Helvetica', 12], -anchor => 'center',
        -tags => ['ghosts_overlay', 'ghosts_active']);
}

1;
