use strict;
use warnings;

use Test::More;
use lib '.';

use Market::ML::GMM;

my @points;
push @points, [$_ / 10, ($_ % 3) / 10] for 0 .. 29;
push @points, [10 + $_ / 10, 10 + ($_ % 3) / 10] for 0 .. 29;
push @points, [($_ % 3) / 10, 10 + $_ / 10] for 0 .. 29;

my $gmm = Market::ML::GMM->new(n_components => 3, max_iter => 100, tolerance => 1e-7);
$gmm->fit(\@points);
is($gmm->n_components, 3, 'fits the requested number of mixture components');
ok(defined $gmm->log_likelihood, 'records final log likelihood');
cmp_ok($gmm->n_iter, '>', 0, 'performs EM iterations');
my $weights_sum = 0;
$weights_sum += $_ for @{$gmm->weights};
cmp_ok(abs($weights_sum - 1), '<', 1e-10, 'mixture weights are normalized');

my $probabilities = $gmm->predict_proba(\@points);
my $max_deviation = 0;
for my $row (@$probabilities) {
    my $sum = 0;
    $sum += $_ for @$row;
    my $deviation = abs($sum - 1);
    $max_deviation = $deviation if $deviation > $max_deviation;
}
cmp_ok($max_deviation, '<', 1e-10, 'each responsibility row is normalized');
my $assignments = $gmm->hard_assignments(\@points);
my $correct = 0;
for my $group (0 .. 2) {
    my %votes;
    $votes{$assignments->[$_]}++ for $group * 30 .. $group * 30 + 29;
    my ($majority) = sort { $votes{$b} <=> $votes{$a} } keys %votes;
    $correct += $votes{$majority};
}
cmp_ok($correct / @points, '>', 0.90, 'recovers the separated synthetic groups instead of only normalizing probabilities');
my $logs = $gmm->component_log_probabilities([ $points[0], $points[40] ]);
ok(!(grep { !defined($_) || $_ != $_ || abs($_) > 1e300 } map { @$_ } @$logs),
    'component log densities remain finite');
my $diagnostics = $gmm->sample_diagnostics([ $points[0], $points[40] ]);
ok(!(grep { $_->{max_responsibility} < 0 || $_->{max_responsibility} > 1
             || $_->{predictability_score} < 0 || $_->{predictability_score} > 1 } @$diagnostics),
    'diagnostic confidences stay in their documented bounds');

my $restored = Market::ML::GMM->from_hash($gmm->to_hash);
is_deeply($restored->predict_proba([ $points[2], $points[70] ]),
    $gmm->predict_proba([ $points[2], $points[70] ]), 'serialized model reproduces probabilities');

eval { Market::ML::GMM->new(n_components => 3)->fit([([1, 1]) x 5]) };
like($@, qr/distinct points/, 'rejects a degenerate mixture instead of duplicating components');

my $serialized = $gmm->to_hash;
eval { Market::ML::GMM->from_hash({ %$serialized, means => [[1], [2], [3]] }) };
like($@, qr/inconsistent feature dimensions/, 'rejects a serialized model whose means have the wrong dimension');
eval { Market::ML::GMM->from_hash({ %$serialized, weights => [0, 0, 0] }) };
like($@, qr/weights sum to zero/, 'rejects a serialized model with an impossible zero mixture');

done_testing();
