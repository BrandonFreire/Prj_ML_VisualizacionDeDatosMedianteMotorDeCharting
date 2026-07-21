use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Overlays::SMC_Structures;

{
    package TestControlsCanvas;
    sub new { bless { calls => [] }, shift }
    sub _record { my ($self, $method, @args) = @_; push @{ $self->{calls} }, [$method, @args]; 1 }
    sub delete          { shift->_record('delete', @_) }
    sub createRectangle { shift->_record('rectangle', @_) }
    sub createText      { shift->_record('text', @_) }
    sub createLine      { shift->_record('line', @_) }
    sub find            { 1 }
    sub lower           { shift->_record('lower', @_) }
    sub by_method {
        my ($self, $method) = @_;
        return [ grep { $_->[0] eq $method } @{ $self->{calls} } ];
    }
    sub tagged {
        my ($self, $tag) = @_;
        return [ grep {
            my $call = $_;
            my $found = 0;
            for my $i (1 .. $#$call - 1) {
                next unless defined($call->[$i]) && !ref($call->[$i])
                    && $call->[$i] eq '-tags';
                my $tags = $call->[$i + 1];
                $found = 1 if ref($tags) eq 'ARRAY' && grep { $_ eq $tag } @$tags;
            }
            $found;
        } @{ $self->{calls} } ];
    }
}

{
    package TestControlsScale;
    sub new { bless { x_width => 1000, y_height => 500, visible_bars => 40 }, shift }
    sub index_to_center_x { return ($_[1] + 0.5) * 25 }
    sub value_to_y { return 400 - $_[1] * 10 }
}

{
    package TestControlsIndicator;
    sub new { bless { fvgs => $_[1], candles => $_[2], events => $_[3] // [] }, $_[0] }
    sub get_fvg_zones { $_[0]{fvgs} }
    sub get_candles { $_[0]{candles} }
    sub get_bos_events { $_[0]{events} }
    sub get_choch_events { [] }
    sub get_ob_zones { [] }
    sub get_swing_highs { [] }
    sub get_swing_lows { [] }
    sub get_external_swing_highs { [] }
    sub get_external_swing_lows { [] }
    sub get_major_highs { [] }
    sub get_major_lows { [] }
    sub get_trendlines { [] }
}

my @candles = map {
    { open => 10 + $_, high => 11 + $_, low => 9 + $_, close => 10 + $_, volume => 1 }
} 0 .. 10;
my $fvg_old = {
    id => 'fvg_old', index => 2, mid_index => 2, left_index => 1,
    formed_at => 3, confirmed_at => 3, direction => 'bull',
    top => 12, bottom => 10, status => 'active', active => 1,
};
my $fvg_new = {
    id => 'fvg_new', index => 5, mid_index => 5, left_index => 4,
    formed_at => 6, confirmed_at => 6, direction => 'bear',
    top => 15, bottom => 14, status => 'active', active => 1,
};

my $visibility = {
    smc_enabled => 1, show_fvg => 1, show_ob => 0,
    show_bos => 0, show_choch => 0, show_internal_structure => 1,
    show_external_structure => 1, show_premium_discount => 0,
    show_trendlines => 0, show_major_levels => 0,
    show_fibonacci_auto => 0, show_market_regime => 0,
};
my $overlay = Market::Overlays::SMC_Structures->new(
    indicator => TestControlsIndicator->new([$fvg_old, $fvg_new], \@candles),
    visibility => $visibility,
);
my $scale = TestControlsScale->new;
my $canvas = TestControlsCanvas->new;
$overlay->render($canvas, 0, 8, $scale, 8);
is(scalar @{ $canvas->tagged('fvg') }, 4,
    'renderiza los dos FVG activos (rectangulo y etiqueta por zona)');
is(scalar @{ $canvas->by_method('rectangle') }, 2,
    'cada FVG activo conserva su propio rectangulo');

my ($old_rect) = grep {
    my $tags;
    for my $i (1 .. $#{$_} - 1) {
                $tags = $_->[$i + 1]
                    if defined($_->[$i]) && !ref($_->[$i]) && $_->[$i] eq '-tags';
    }
    ref($tags) eq 'ARRAY' && grep { $_ eq 'fvg_fvg_old' } @$tags;
} @{ $canvas->by_method('rectangle') };
my $half_body = 25 * 0.35;
is($old_rect->[1], $scale->index_to_center_x(2) - $half_body,
    'el FVG empieza en el borde del cuerpo de la vela central');
is($old_rect->[3], $scale->index_to_center_x(8) + $half_body,
    'el FVG termina en el borde del cuerpo de la ultima vela, sin sobresalir media columna');

$visibility->{show_fvg} = 0;
$canvas = TestControlsCanvas->new;
$overlay->render($canvas, 0, 8, $scale, 8);
is(scalar @{ $canvas->by_method('rectangle') }, 0,
    'desactivar FVG elimina inmediatamente todas sus zonas');

my $event = {
    id => 'bos_internal_bull', index => 4, break_index => 4,
    from => 1, pivot_index => 1, level => 10, direction => 'bull',
    scope => 'internal', confirmed_at => 4, scope_confirmed_at => 4,
};
my $fib_visibility = { %$visibility, show_fvg => 0, show_fibonacci_auto => 1 };
my $fib_overlay = Market::Overlays::SMC_Structures->new(
    indicator => TestControlsIndicator->new([], \@candles, [$event]),
    visibility => $fib_visibility,
);
$canvas = TestControlsCanvas->new;
$fib_overlay->render($canvas, 0, 5, $scale, 5);
is(scalar @{ $canvas->by_method('line') }, 7,
    'Fibonacci automatico dibuja sus siete niveles');
cmp_ok(scalar(@{ $canvas->tagged('fibonacci') }), '>=', 7,
    'lineas y etiquetas Fibonacci reciben tags controlables');

$fib_visibility->{show_fibonacci_auto} = 0;
$canvas = TestControlsCanvas->new;
$fib_overlay->render($canvas, 0, 5, $scale, 5);
is(scalar @{ $canvas->tagged('fibonacci') }, 0,
    'Fibonacci automatico se puede desactivar sin dejar elementos residuales');

done_testing();
