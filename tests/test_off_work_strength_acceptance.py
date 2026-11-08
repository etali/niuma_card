# SPDX-License-Identifier: AGPL-3.0-only
import importlib.util
from pathlib import Path
import unittest
import random

spec=importlib.util.spec_from_file_location('off_work_strength',Path(__file__).resolve().parents[1]/'tools/off_work_check_bot_strength.py')
module=importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

def report(*winners, seed=1):
    return {'matches':[{'winner':winner,'a_work':0,'b_work':50,'seed':seed,'a_seat':seat} for seat,winner in enumerate(winners)]}

class AcceptanceTests(unittest.TestCase):
    def test_small_sample_cannot_pass_even_all_wins(self):
        self.assertFalse(module.summarize([report('a','a',seed=seed) for seed in range(1,3)])['passed'])
    def test_timeout_is_not_a_draw_or_win(self):
        result=module.summarize([report('a','timeout',seed=seed) for seed in range(1,13)])
        self.assertEqual(result['higher_score_rate'],.5)
        self.assertEqual(result['draws'],0)
        self.assertFalse(result['passed'])
    def test_equal_and_reverse_pairs_fail(self):
        for winners in [('a','b'),('b','b')]:
            self.assertFalse(module.summarize([report(*winners,seed=seed) for seed in range(1,13)])['passed'])
    def test_minimum_cannot_be_bypassed(self):
        self.assertFalse(module.summarize([report('a','a')],minimum_pairs=1)['passed'])
    def test_mixed_runtime_or_parameters_are_rejected(self):
        for key in ('simulator_fingerprint','godot_version','profiles'):
            old=report('a','a',seed=1);new=report('a','a',seed=2)
            old[key]='old';new[key]='new'
            with self.assertRaises(ValueError):module.summarize([old,new])
    def test_one_ulp_json_round_trip_is_equal(self):
        self.assertTrue(module.same_profile({'buy_chance':.468},{'buy_chance':.46799999999999997}))
    def test_real_profile_changes_and_discrete_changes_are_rejected(self):
        for actual,requested in [({'buy_chance':.46800000001},{'buy_chance':.468}),
            ({'desired_people':9},{'desired_people':8}),({'desired_people':8.000000000000002},{'desired_people':8}),
            ({'active':True},{'active':1}),({'buy_chance':.468},{}),({'x':float('nan')},{'x':float('nan')})]:
            self.assertFalse(module.same_profile(actual,requested))
    def test_bootstrap_is_invariant_to_parallel_completion_order(self):
        pairs=[report('b','b') for _ in range(4)]+[report('a','b')]+[report('a','a') for _ in range(7)]
        for seed,pair in enumerate(pairs,100):
            for game in pair['matches']:game['seed']=seed
        expected=module.summarize(pairs)
        for seed in range(5):
            shuffled=pairs[:];random.Random(seed).shuffle(shuffled)
            self.assertEqual(module.summarize(shuffled),expected)
    def test_duplicate_seed_pairs_cannot_pass_as_independent_samples(self):
        with self.assertRaises(ValueError):module.summarize([report('a','a',seed=98001)]*12)
    def test_incomplete_or_mismatched_pairs_are_rejected(self):
        incomplete=report('a');wrong_seat=report('a','a');wrong_seat['matches'][1]['a_seat']=0
        wrong_seed=report('a','a');wrong_seed['matches'][1]['seed']=2
        wrong_outcome=report('a','unknown')
        for pair in [incomplete,wrong_seat,wrong_seed,wrong_outcome]:
            with self.assertRaises(ValueError):module.summarize([pair])
    def test_clear_paired_advantage_passes(self):
        self.assertTrue(module.summarize([report('a','a',seed=seed) for seed in range(1,13)])['passed'])

if __name__=='__main__':unittest.main()
