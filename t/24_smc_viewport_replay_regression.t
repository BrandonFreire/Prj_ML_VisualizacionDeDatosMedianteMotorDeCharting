use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Indicators::SMC_Structures;
use Market::Overlays::SMC_Structures;

my $fvg = {
    id=>'fvg_bull_1_2_3', index=>2, left_index=>1, formed_at=>3,
    confirmed_at=>3, direction=>'bull', top=>12, bottom=>10,
    status=>'mitigated', active=>0, mitigated_at=>9, end_index=>9,
    fill_events=>[
        { index=>7, fill_ratio=>0.5, top=>11, bottom=>10 },
        { index=>9, fill_ratio=>1, top=>10, bottom=>10 },
    ],
};

is(
    Market::Overlays::SMC_Structures::_select_latest_active_fvg([$fvg], 8)->{id},
    'fvg_bull_1_2_3',
    'el mismo FVG está activo antes de su mitigación',
);
ok(
    !Market::Overlays::SMC_Structures::_select_latest_active_fvg([$fvg], 9),
    'el FVG deja de ser seleccionable exactamente al mitigarse',
);

{
    package TestSMCViewportCanvas;
    sub new { bless { calls=>[] }, shift }
    sub delete { 1 }
    sub createRectangle { my ($s,@a)=@_; push @{$s->{calls}}, ['rect',@a]; 1 }
    sub createText { my ($s,@a)=@_; push @{$s->{calls}}, ['text',@a]; 1 }
    sub createLine { my ($s,@a)=@_; push @{$s->{calls}}, ['line',@a]; 1 }
    sub find { 1 }
    sub lower { my ($s,@a)=@_; push @{$s->{calls}}, ['lower',@a]; 1 }
    sub rectangles { [ grep { $_->[0] eq 'rect' } @{$_[0]{calls}} ] }
    sub lines { [ grep { $_->[0] eq 'line' } @{$_[0]{calls}} ] }
    sub lowered { [ grep { $_->[0] eq 'lower' } @{$_[0]{calls}} ] }
}
{
    package TestSMCViewportScale;
    sub new { bless { x_width=>1000, y_height=>500, visible_bars=>$_[1] }, $_[0] }
    sub index_to_center_x { 25 + ($_[1] - 0) * 25 }
    sub value_to_y { 400 - $_[1] * 10 }
}
{
    package TestSMCViewportIndicator;
    sub new { bless { fvg=>$_[1] }, $_[0] }
    sub get_fvg_zones { [ $_[0]{fvg} ] }
}

my $visibility = {
    smc_enabled=>1, show_fvg=>1, show_ob=>0, show_bos=>0, show_choch=>0,
    show_internal_structure=>1, show_external_structure=>1,
    show_premium_discount=>0, show_trendlines=>0, show_major_levels=>0,
    show_fibonacci_auto=>0, show_market_regime=>0,
};
my $overlay = Market::Overlays::SMC_Structures->new(
    indicator=>TestSMCViewportIndicator->new($fvg), visibility=>$visibility,
);
my @ids;
for my $window ([0,8,40], [2,8,20], [6,8,8]) {
    my ($start,$end,$bars)=@$window;
    my $canvas=TestSMCViewportCanvas->new;
    $overlay->_render_fvg($canvas,$start,$end,TestSMCViewportScale->new($bars),8,{});
    is(scalar @{$canvas->rectangles}, 1, "el FVG se recorta en zoom $bars sin reseleccionarse");
    push @ids, $fvg->{id};
}
is_deeply(\@ids, [('fvg_bull_1_2_3') x 3], 'el ID seleccionado no depende del viewport');

for my $window ([0,9,40], [5,9,8]) {
    my $canvas=TestSMCViewportCanvas->new;
    $overlay->_render_fvg($canvas,$window->[0],$window->[1],TestSMCViewportScale->new($window->[2]),9,{});
    is(scalar @{$canvas->rectangles}, 0, 'el FVG mitigado no reaparece en otro zoom');
}

$visibility->{show_fvg}=0;
my $canvas=TestSMCViewportCanvas->new;
$overlay->render($canvas,0,8,TestSMCViewportScale->new(20),8);
is(scalar @{$canvas->rectangles}, 0, 'el toggle FVG apagado elimina toda zona');

$visibility->{show_fvg}=1;
$canvas=TestSMCViewportCanvas->new;
$overlay->render($canvas,0,8,TestSMCViewportScale->new(20),8);
is_deeply($canvas->lowered->[0], ['lower','smc_zone','candles'],
    'las zonas SMC se bajan detrÃ¡s de las velas despuÃ©s de renderizar');

{
    package TestSMCTrendIndicator;
    sub new { bless {}, shift }
    sub get_trendlines {
        [
            { id=>'tl_internal', direction=>'bull', scope=>'internal',
              from_index=>1, to_index=>3, from_price=>10, to_price=>12,
              confirmed_at=>3, break_at=>5 },
            { id=>'tl_external', direction=>'bull', scope=>'external',
              from_index=>0, to_index=>4, from_price=>9, to_price=>13,
              confirmed_at=>4 },
        ]
    }
}
my $trend_overlay = Market::Overlays::SMC_Structures->new(
    indicator=>TestSMCTrendIndicator->new, visibility=>$visibility,
);
$canvas=TestSMCViewportCanvas->new;
$trend_overlay->_render_trendlines($canvas,0,8,TestSMCViewportScale->new(20),8);
is(scalar @{$canvas->lines}, 2,
    'trendlines internas y externas no se ocultan entre sÃ­ por compartir direcciÃ³n');
my $broken_endpoint = scalar grep {
    $_->[3] == TestSMCViewportScale->new(20)->index_to_center_x(5)
} @{$canvas->lines};
ok($broken_endpoint, 'la trendline rota termina exactamente en la vela de ruptura');

my @candles = map { { close=>$_ } } (10, 10, 8, 12, 11, 7);
my @highs = ({ index=>1, price=>11, confirmed_at=>1, scope=>'internal', swept=>0 });
my @lows  = ({ index=>1, price=>9,  confirmed_at=>1, scope=>'internal', swept=>0 });
my ($bos,$choch) = Market::Indicators::SMC_Structures::_detect_bos_choch(
    \@candles, \@highs, \@lows, 'internal', 1, {},
);
is(scalar @$bos, 1, 'el primer quiebre bajista es BOS del scope interno');
is(scalar @$choch, 1, 'el quiebre contrario posterior es CHoCH interno');
is($choch->[0]{previous_trend}, -1, 'CHoCH conserva el bias anterior de su propio scope');
ok($bos->[0]{crossed} && $choch->[0]{crossed}, 'cada evento registra el nivel consumido');

my @already_above = map { { close=>$_ } } (9, 11, 12, 13);
my @late_high = ({ index=>0, price=>10, confirmed_at=>2, scope=>'external', swept=>0 });
my ($late_bos,$late_choch) = Market::Indicators::SMC_Structures::_detect_bos_choch(
    \@already_above, \@late_high, [], 'external', 1, {},
);
is_deeply([$late_bos,$late_choch], [[],[]], 'no inventa ruptura si el cierre ya estaba sobre el pivote al confirmarse');

my @external_candles = map { { close=>$_ } } (10,10,12,11,8,10,7,13);
my @external_highs = (
    { index=>1, price=>11, confirmed_at=>1, scope=>'external', swept=>0 },
    { index=>3, price=>12, confirmed_at=>3, scope=>'external', swept=>0 },
);
my @external_lows = (
    { index=>1, price=>9, confirmed_at=>1, scope=>'external', swept=>0 },
    { index=>5, price=>8, confirmed_at=>5, scope=>'external', swept=>0 },
);
my ($external_bos,$external_choch) =
    Market::Indicators::SMC_Structures::_detect_bos_choch(
        \@external_candles, \@external_highs, \@external_lows, 'external', 1, {},
    );
is_deeply([map { $_->{direction} } @$external_bos], [qw(bull bear)],
    'el scope externo conserva BOS de continuacion alcista y bajista');
is_deeply([map { $_->{direction} } @$external_choch], [qw(bear bull)],
    'el scope externo conserva CHoCH en ambos cambios de bias');
is(scalar(grep { ($_->{scope}//'') ne 'external' } @$external_bos, @$external_choch), 0,
    'todos los eventos externos permanecen en su propio scope');
is(scalar(grep { !$_->{swept} } @external_highs, @external_lows), 0,
    'cada nivel externo consumido queda cruzado una sola vez');

done_testing();
