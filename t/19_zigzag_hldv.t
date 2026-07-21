use strict;
use warnings;

use Test::More;
use lib '.';

use Market::Indicators::ZigZagDirection;

my $labeled = Market::Indicators::ZigZagDirection::_annotate_hldv([
    { type => 'high', index => 1, price => 10, confirmed_at => 2 },
    { type => 'low',  index => 3, price => 5,  confirmed_at => 4 },
    { type => 'high', index => 5, price => 12, confirmed_at => 6 },
    { type => 'low',  index => 7, price => 6,  confirmed_at => 8 },
    { type => 'high', index => 9, price => 11, confirmed_at => 10 },
    { type => 'low',  index => 11, price => 4, confirmed_at => 12 },
]);

is_deeply([ map { $_->{label} } @$labeled ], [qw(LH LL HH HL LH LL)],
    'clasifica HH/HL/LH/LL comparando cada extremo con el anterior del mismo tipo');
ok(!(grep { !defined($_->{confirmed_at}) } @$labeled),
    'las etiquetas conservan la barrera temporal de sus pivotes confirmados');

my $prefix = Market::Indicators::ZigZagDirection::_annotate_hldv([ @$labeled[0 .. 3] ]);
is_deeply([ map { $_->{label} } @$prefix ], [qw(LH LL HH HL)],
    'las etiquetas de un prefijo no dependen de pivotes futuros');

my $developing = Market::Indicators::ZigZagDirection::_append_developing_pivot(
    [{ id=>'confirmed_high', type=>'high', index=>1, price=>10, confirmed_at=>2 }],
    [
        { high=>9,  low=>7 }, { high=>10, low=>8 },
        { high=>12, low=>7 }, { high=>11, low=>6 },
    ],
    3,
);
is($developing->[0]{id}, 'confirmed_high',
    'un máximo confirmado no se reemplaza con datos posteriores');
is($developing->[1]{type}, 'low',
    'el extremo provisional alterna respecto al último confirmado');
ok($developing->[1]{provisional}, 'el extremo móvil queda marcado como provisional');

done_testing();
