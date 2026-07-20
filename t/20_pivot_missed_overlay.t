use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Overlays::PivotMissedReversal;

{
    package TestPMRCanvas;

    sub new { return bless { calls => [] }, shift }

    sub _record {
        my ($self, $method, @args) = @_;
        push @{ $self->{calls} }, { method => $method, args => \@args };
        return scalar @{ $self->{calls} };
    }

    sub delete          { shift->_record('delete',          @_) }
    sub createLine      { shift->_record('createLine',      @_) }
    sub createRectangle { shift->_record('createRectangle', @_) }
    sub createOval      { shift->_record('createOval',      @_) }
    sub createPolygon   { shift->_record('createPolygon',   @_) }

    sub clear { $_[0]->{calls} = [] }

    sub calls_with_tag {
        my ($self, $tag, $method) = @_;
        my @matches;
        for my $call (@{ $self->{calls} }) {
            next if defined $method && $call->{method} ne $method;
            my @args = @{ $call->{args} };
            for (my $i = 0; $i < $#args; $i++) {
                next unless defined $args[$i] && !ref($args[$i]) && $args[$i] eq '-tags';
                my $tags = $args[$i + 1];
                my @tags = ref($tags) eq 'ARRAY' ? @$tags : ($tags);
                if (grep { defined $_ && $_ eq $tag } @tags) {
                    push @matches, $call;
                    last;
                }
            }
        }
        return \@matches;
    }
}

{
    package TestPMRScale;

    sub new { return bless { y_height => 300, x_width => 500 }, shift }
    sub index_to_center_x { return 5 + $_[1] * 10 }
    sub value_to_y        { return 250 - $_[1] * 5 }
}

{
    package TestPMRIndicator;

    sub new {
        return bless {
            regular => [
                { source => 'regular', type => 'high', index => 2, price => 15, confirmed_at => 4 },
                { source => 'regular', type => 'low',  index => 4, price => 4,  confirmed_at => 6 },
            ],
            missed => [
                { source => 'missed', type => 'low',  index => 3, price => 5,  confirmed_at => 6 },
                { source => 'missed', type => 'high', index => 7, price => 18, confirmed_at => 9 },
            ],
            levels => [
                { type => 'low',  price => 5,  start_index => 3, end_index => 9,
                  created_at => 6, active => 0 },
                { type => 'high', price => 18, start_index => 7, end_index => 10,
                  created_at => 9, active => 1 },
            ],
        }, shift;
    }

    sub get_regular_pivots  { return $_[0]->{regular} }
    sub get_missed_pivots   { return $_[0]->{missed} }
    sub get_reversal_levels { return $_[0]->{levels} }
}

{
    package TestPMRIndicatorProvisional;
    our @ISA = ('TestPMRIndicator');

    sub get_provisional_pivot_at {
        my ($self, $current_bar) = @_;
        return undef if $current_bar < 8;
        return {
            source => 'provisional', provisional => 1,
            type => 'low', index => 7, price => 3,
            from_index => 4, from_price => 4,
            max_visible_index => $current_bar,
        };
    }
}

my $visibility = {
    pmr_enabled       => 1,
    show_pmr_regular  => 1,
    show_pmr_missed   => 1,
    show_pmr_levels   => 1,
    show_pmr_segments => 1,
};
my $overlay = Market::Overlays::PivotMissedReversal->new(
    indicator  => TestPMRIndicator->new,
    visibility => $visibility,
);
my $canvas = TestPMRCanvas->new;
my $scale  = TestPMRScale->new;

$overlay->render($canvas, 0, 10, $scale, 4);
is(scalar @{ $canvas->calls_with_tag('pmr_regular', 'createPolygon') }, 1,
    'el pivot regular aparece justo al confirmarse');
is(scalar @{ $canvas->calls_with_tag('pmr_ghost', 'createRectangle') }, 0,
    'el fantasma no aparece antes de su confirmación');
is(scalar @{ $canvas->calls_with_tag('pmr_level', 'createLine') }, 0,
    'el nivel fantasma tampoco se adelanta en Replay');
is(scalar @{ $canvas->calls_with_tag('pmr_segment', 'createLine') }, 0,
    'no inventa un segmento sin dos extremos visibles');

$canvas->clear;
$overlay->render($canvas, 0, 10, $scale, 6);
my $ghost_rects = $canvas->calls_with_tag('pmr_ghost', 'createRectangle');
is(scalar @$ghost_rects, 1, 'el missed pivot confirmado dibuja un fantasma');
is($ghost_rects->[0]{args}[0], 26,
    'el fantasma se coloca sobre la vela extrema y no sobre la vela de confirmación');
my $level_lines = $canvas->calls_with_tag('pmr_level', 'createLine');
is(scalar @$level_lines, 1, 'dibuja el nivel asociado al fantasma');
is($level_lines->[0]{args}[2], 65,
    'el nivel queda cortado exactamente en el cursor de Replay');
ok(@{ $canvas->calls_with_tag('pmr_segment', 'createLine') } >= 1,
    'los segmentos opcionales conectan únicamente extremos ya visibles');

$canvas->clear;
$overlay->render($canvas, 0, 10, $scale, 9);
is(scalar @{ $canvas->calls_with_tag('pmr_ghost', 'createRectangle') }, 2,
    'cada missed pivot aparece cuando alcanza su propia confirmación');
is(scalar @{ $canvas->calls_with_tag('pmr_level', 'createLine') }, 2,
    'los niveles históricos y el activo se conservan en pantalla');

$visibility->{show_pmr_missed} = 0;
$canvas->clear;
$overlay->render($canvas, 0, 10, $scale, 9);
is(scalar @{ $canvas->calls_with_tag('pmr_ghost', 'createRectangle') }, 0,
    'el interruptor de fantasmas oculta solamente sus iconos');
is(scalar @{ $canvas->calls_with_tag('pmr_level', 'createLine') }, 2,
    'los niveles tienen un interruptor independiente');

$visibility->{pmr_enabled} = 0;
$canvas->clear;
$overlay->render($canvas, 0, 10, $scale, 9);
is(scalar @{ $canvas->calls_with_tag('pmr_overlay') }, 0,
    'el interruptor principal elimina todo el overlay');
is($canvas->{calls}[0]{method}, 'delete',
    'al apagar el módulo también limpia cualquier dibujo anterior');

my $provisional_visibility = {
    pmr_enabled         => 1,
    show_pmr_regular    => 0,
    show_pmr_missed     => 0,
    show_pmr_levels     => 0,
    show_pmr_segments   => 0,
    show_pmr_provisional => 1,
};
my $provisional_overlay = Market::Overlays::PivotMissedReversal->new(
    indicator  => TestPMRIndicatorProvisional->new,
    visibility => $provisional_visibility,
);
$canvas->clear;
$provisional_overlay->render($canvas, 0, 10, $scale, 7);
is(scalar @{ $canvas->calls_with_tag('pmr_provisional') }, 0,
    'el fantasma provisional tampoco aparece antes de existir en el cursor');

$canvas->clear;
$provisional_overlay->render($canvas, 0, 10, $scale, 8);
is(scalar @{ $canvas->calls_with_tag('pmr_provisional', 'createRectangle') }, 1,
    'dibuja exactamente un fantasma provisional vigente');
is(scalar @{ $canvas->calls_with_tag('pmr_provisional_segment', 'createLine') }, 1,
    'el provisional incluye su tramo móvil discontinuo');
is(scalar @{ $canvas->calls_with_tag('pmr_provisional_level', 'createLine') }, 1,
    'el provisional proyecta su nivel sólo hasta el cursor');

done_testing();
