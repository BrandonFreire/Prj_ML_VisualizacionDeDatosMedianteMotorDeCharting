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
        my @candles = map { { high => 15, low => 11 } } 0..8;
        $candles[3]{low} = 9;
        bless {
            _candles => \@candles,
            obs => [
                { index=>1, triggered_by=>2, confirmed_at=>2, direction=>'bull',
                  top=>10, bottom=>8, scope=>'internal', scope_confirmed_at=>2,
                  relevant=>1, relevance_score=>3 },
                { index=>4, triggered_by=>5, confirmed_at=>5, direction=>'bear',
                  top=>22, bottom=>20, scope=>'external', scope_confirmed_at=>5,
                  relevant=>1, relevance_score=>4 },
                { index=>6, triggered_by=>6, confirmed_at=>6, direction=>'bull',
                  top=>14, bottom=>13.9, scope=>'internal', scope_confirmed_at=>6,
                  relevant=>0, relevance_score=>0.2 },
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
is(scalar @{$canvas->tagged('ob_internal')}, 1, 'dibuja el Order Block interno');
is(scalar @{$canvas->tagged('ob_external')}, 1, 'dibuja el Order Block externo');
is(scalar @{$canvas->tagged('ob_historical')}, 1,
    'conserva el bloque histórico hasta su mitigación');
is(scalar @{$canvas->tagged('ob_active')}, 1, 'extiende el bloque activo hasta el cursor');

$visibility->{show_internal_structure} = 0;
$canvas->{calls} = [];
$overlay->render($canvas, 0, 8, TestOBScale->new, 8);
is(scalar @{$canvas->tagged('ob_internal')}, 0, 'Internal apagado oculta sólo OB internos');
is(scalar @{$canvas->tagged('ob_external')}, 1, 'External conserva los OB externos');

$visibility->{show_internal_structure} = 1;
$visibility->{show_external_structure} = 0;
$canvas->{calls} = [];
$overlay->render($canvas, 0, 8, TestOBScale->new, 8);
is(scalar @{$canvas->tagged('ob_internal')}, 1, 'Internal vuelve a mostrar OB internos');
is(scalar @{$canvas->tagged('ob_external')}, 0, 'External apagado oculta sólo OB externos');

done_testing();
