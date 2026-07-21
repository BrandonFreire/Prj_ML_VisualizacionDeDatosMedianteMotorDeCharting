use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Overlays::SMC_Structures;

{
    package TestOBCanvas;
    sub new { bless { calls => [] }, shift }
    sub _rec { my ($s,$m,@a)=@_; push @{$s->{calls}}, [$m,@a]; 1 }
    sub delete          { shift->_rec('delete', @_) }
    sub createRectangle { shift->_rec('createRectangle', @_) }
    sub createText      { shift->_rec('createText', @_) }
    sub tagged {
        my ($s,$tag)=@_;
        return [ grep {
            my @a=@$_; my $found=0;
            for my $i (0..$#a-1) {
                next unless defined($a[$i]) && !ref($a[$i]) && $a[$i] eq '-tags';
                my $tags=$a[$i+1];
                $found=1 if ref($tags) eq 'ARRAY' && grep { $_ eq $tag } @$tags;
            }
            $found;
        } @{$s->{calls}} ];
    }
}

{
    package TestOBScale;
    sub new { bless { x_width => 900, y_height => 500, visible_bars => 9 }, shift }
    sub index_to_center_x { 50 + $_[1] * 100 }
    sub value_to_y { 400 - $_[1] * 10 }
}

{
    package TestOBIndicator;
    sub new {
        bless {
            obs => [
                { id=>'i_bull', index=>1, triggered_by=>2, confirmed_at=>2, direction=>'bull',
                  top=>10, bottom=>8, scope=>'internal', scope_confirmed_at=>2,
                  active=>1, status=>'active', relevance_score=>3 },
                { id=>'i_bear', index=>2, triggered_by=>3, confirmed_at=>3, direction=>'bear',
                  top=>18, bottom=>16, scope=>'internal', scope_confirmed_at=>3,
                  active=>1, status=>'active', relevance_score=>2 },
                { id=>'e_bull', index=>3, triggered_by=>4, confirmed_at=>4, direction=>'bull',
                  top=>7, bottom=>5, scope=>'external', scope_confirmed_at=>4,
                  active=>1, status=>'active', relevance_score=>2 },
                { id=>'e_bear', index=>4, triggered_by=>5, confirmed_at=>5, direction=>'bear',
                  top=>22, bottom=>20, scope=>'external', scope_confirmed_at=>5,
                  active=>1, status=>'active', relevance_score=>4 },
                { index=>6, triggered_by=>6, confirmed_at=>6, direction=>'bull',
                  top=>14, bottom=>13.9, scope=>'internal', scope_confirmed_at=>6,
                  active=>0, status=>'mitigated', end_index=>7, relevance_score=>0.2 },
            ],
        }, shift;
    }
    sub get_ob_zones     { $_[0]{obs} }
    sub get_swing_highs  { [] }
    sub get_swing_lows   { [] }
    sub get_major_highs  { [] }
    sub get_major_lows   { [] }
    sub get_bos_events   { [] }
    sub get_choch_events { [] }
    sub get_fvg_zones    { [] }
    sub get_trendlines   { [] }
}

my $visibility = {
    smc_enabled => 1, show_ob => 1,
    show_internal_ob => 1, show_external_ob => 1,
    show_internal_structure => 1, show_external_structure => 1,
    show_premium_discount => 0, show_trendlines => 0,
    show_major_levels => 0, show_fvg => 0, show_bos => 0,
    show_choch => 0, show_fibonacci_auto => 0, show_market_regime => 0,
};
my $overlay = Market::Overlays::SMC_Structures->new(
    indicator => TestOBIndicator->new, visibility => $visibility,
);
my $canvas = TestOBCanvas->new;
$overlay->render($canvas, 0, 8, TestOBScale->new, 8);
is(scalar @{$canvas->tagged('ob_internal')}, 2, 'dibuja Order Blocks internos alcista y bajista');
is(scalar @{$canvas->tagged('ob_external')}, 2, 'dibuja Order Blocks externos alcista y bajista');
is(scalar @{$canvas->tagged('ob_historical')}, 0,
    'un bloque mitigado no permanece en la gráfica');
is(scalar @{$canvas->tagged('ob_active')}, 4, 'extiende únicamente bloques activos hasta el cursor');

$visibility->{show_ob} = 0;
$canvas->{calls} = [];
$overlay->render($canvas, 0, 8, TestOBScale->new, 8);
is(scalar @{$canvas->tagged('ob_active')}, 0,
    'el control maestro Order Blocks oculta internos y externos');
$visibility->{show_ob} = 1;

$visibility->{show_internal_ob} = 0;
$canvas->{calls} = [];
$overlay->render($canvas, 0, 8, TestOBScale->new, 8);
is(scalar @{$canvas->tagged('ob_internal')}, 0, 'Internal apagado oculta sólo OB internos');
is(scalar @{$canvas->tagged('ob_external')}, 2, 'External conserva los OB externos');

$visibility->{show_internal_ob} = 1;
$visibility->{show_external_ob} = 0;
$canvas->{calls} = [];
$overlay->render($canvas, 0, 8, TestOBScale->new, 8);
is(scalar @{$canvas->tagged('ob_internal')}, 2, 'Internal vuelve a mostrar OB internos');
is(scalar @{$canvas->tagged('ob_external')}, 0, 'External apagado oculta sólo OB externos');

$visibility->{show_internal_ob} = 0;
$canvas->{calls} = [];
$overlay->render($canvas, 0, 8, TestOBScale->new, 8);
is(scalar @{$canvas->tagged('ob_active')}, 0, 'ambos controles apagados ocultan todos los OB');

$visibility->{show_internal_ob} = 1;
$visibility->{show_external_ob} = 1;
$canvas->{calls} = [];
$overlay->render($canvas, 4, 8, TestOBScale->new, 8);
is(scalar @{$canvas->tagged('ob_i_bull')}, 1,
    'el mismo OB activo se conserva al cambiar el viewport y sólo se recorta');

done_testing();
