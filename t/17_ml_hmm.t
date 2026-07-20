use strict;
use warnings;

use Test::More;
use lib '.';

use Market::ML::HMM;

my $hmm = Market::ML::HMM->new(
    states => [qw(Healthy Fever)], pi => [0.6, 0.4],
    A => [ [0.7, 0.3], [0.4, 0.6] ],
);
my $emissions = Market::ML::HMM->log_emissions_from_discrete(
    [ [0.5, 0.4, 0.1], [0.1, 0.3, 0.6] ], [0, 1, 2],
);
my $viterbi = $hmm->viterbi($emissions);
is_deeply($viterbi->{state_names}, [qw(Healthy Healthy Fever)], 'Viterbi reproduces the reference path for retrospective diagnostics');
is($viterbi->{replay_safe}, 0, 'Viterbi explicitly declares that its full path is retrospective');

my $filtered = $hmm->forward_filter($emissions);
is(scalar @{$filtered->{state_names}}, 3, 'forward filter returns one state per observation');
ok($filtered->{replay_safe}, 'forward filter is explicitly causal');
for my $posterior (@{$filtered->{posteriors}}) {
    my $sum = 0; $sum += $_ for @$posterior;
    cmp_ok(abs($sum - 1), '<', 1e-12, 'each filtered posterior is normalized');
}

my $prefix = $hmm->forward_filter([@$emissions[0, 1]]);
my $extended = $hmm->forward_filter([@$emissions, [log(0.001), log(0.999)]]);
is_deeply($prefix->{posteriors}, [@{$extended->{posteriors}}[0, 1]],
    'future emissions do not revise previous forward-filter states');

my $transitions = Market::ML::HMM->estimate_transition_matrix([0, 0, 1, 2, 1, 1, 0], n_states => 3);
for my $row (@$transitions) {
    my $sum = 0; $sum += $_ for @$row;
    cmp_ok(abs($sum - 1), '<', 1e-12, 'estimated transition rows are normalized');
}
my $restored = Market::ML::HMM->from_hash($hmm->to_hash);
is_deeply($restored->forward_filter($emissions)->{posteriors}, $filtered->{posteriors},
    'serialized HMM preserves causal inference');

done_testing();
