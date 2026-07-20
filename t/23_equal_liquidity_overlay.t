use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Overlays::Liquidity;

{
    package TestEQCanvas;
    sub new { bless { calls => [] }, shift }
    sub _rec { my ($s,$m,@a)=@_; push @{$s->{calls}}, { method=>$m, args=>\@a }; 1 }
    sub delete     { shift->_rec('delete', @_) }
    sub createLine { shift->_rec('createLine', @_) }
    sub createText { shift->_rec('createText', @_) }
    sub tagged {
        my ($s,$tag,$method)=@_;
        return [ grep {
            my $call=$_; my $found=0;
            if (!defined($method) || $call->{method} eq $method) {
                my @a=@{$call->{args}};
                for my $i (0..$#a-1) {
                    next unless defined($a[$i]) && !ref($a[$i]) && $a[$i] eq '-tags';
                    $found=1 if ref($a[$i+1]) eq 'ARRAY' && grep { $_ eq $tag } @{$a[$i+1]};
                }
            }
            $found;
        } @{$s->{calls}} ];
    }
}

{
    package TestEQScale;
    sub new { bless { x_width=>1000, y_height=>500, visible_bars=>20 }, shift }
    sub index_to_center_x { 25 + $_[1] * 50 }
    sub value_to_y { 400 - $_[1] * 3 }
}

{
    package TestEQIndicator;
    sub new {
        my @levels;
        push @levels, map {
            { side=>'sh', type=>'BSL', index=>$_, price=>105+$_,
              confirmed_at=>$_+1, scope=>'internal', state=>'DETECTED' }
        } 5..14;
        push @levels, {
            side=>'sh', type=>'BSL', index=>4, price=>100.04,
            confirmed_at=>5, scope=>'internal', state=>'DETECTED',
            is_eqh=>1, eq_pair=>1, eq_pair_price=>100,
            eq_price=>100.02, eq_confirmed_at=>5, eq_pair_confirmed_at=>2,
            eq_deviation_atr=>0.04,
        };
        push @levels, {
            side=>'sl', type=>'SSL', index=>8, price=>89.96,
            confirmed_at=>9, scope=>'internal', state=>'DETECTED',
            is_eql=>1, eq_pair=>3, eq_pair_price=>90,
            eq_price=>89.98, eq_confirmed_at=>9, eq_pair_confirmed_at=>4,
            eq_deviation_atr=>0.04,
        };
        bless { levels=>\@levels }, shift;
    }
    sub get_levels { $_[0]{levels} }
}

my $visibility = {
    liquidity_enabled=>1, show_bsl=>1, show_ssl=>0,
    show_eqh=>1, show_eql=>1,
    show_internal_structure=>1, show_external_structure=>1,
    show_sweep=>0, show_grab=>0, show_run=>0,
};
my $overlay = Market::Overlays::Liquidity->new(
    indicator=>TestEQIndicator->new, visibility=>$visibility, max_levels=>8,
);
my $canvas = TestEQCanvas->new;
$overlay->render($canvas, 0, 19, TestEQScale->new, 19);
my $lines = $canvas->tagged('lq_EQH', 'createLine');
is(scalar @$lines, 1, 'EQH conserva un cupo propio aunque existan más de ocho BSL recientes');
is($lines->[0]{args}[1], $lines->[0]{args}[3],
    'el conector EQH es horizontal al precio medio del par');
my $low_lines = $canvas->tagged('lq_EQL', 'createLine');
is(scalar @$low_lines, 1, 'EQL se dibuja aunque la línea SSL base esté apagada');
is($low_lines->[0]{args}[1], $low_lines->[0]{args}[3],
    'el conector EQL también es horizontal');

$visibility->{show_eqh}=0;
$canvas->{calls}=[];
$overlay->render($canvas, 0, 19, TestEQScale->new, 19);
is(scalar @{$canvas->tagged('lq_EQH', 'createLine')}, 0,
    'el interruptor EQH oculta sus conectores sin depender de BSL');
is(scalar @{$canvas->tagged('lq_EQL', 'createLine')}, 1,
    'apagar EQH no afecta los conectores EQL');

$visibility->{show_eql}=0;
$canvas->{calls}=[];
$overlay->render($canvas, 0, 19, TestEQScale->new, 19);
is(scalar @{$canvas->tagged('lq_EQL', 'createLine')}, 0,
    'el interruptor EQL oculta sus conectores independientemente');

done_testing();
