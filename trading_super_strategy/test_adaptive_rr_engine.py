import unittest

from adaptive_rr_engine import (
    AdaptiveRiskRewardEngine,
    PositionRiskState,
    RRCandidate,
    validate_stop_update,
)


class AdaptiveRiskRewardEngineTests(unittest.TestCase):
    def setUp(self):
        self.engine = AdaptiveRiskRewardEngine(min_samples=20)

    def test_negative_ratio_can_be_selected_when_ev_is_positive(self):
        decision = self.engine.select([
            RRCandidate(0.5, p_win=0.76, samples=100, cost_r=0.02, oos_stability=0.85),
            RRCandidate(2.0, p_win=0.32, samples=100, cost_r=0.02, oos_stability=0.85),
        ])
        self.assertTrue(decision.accepted)
        self.assertEqual(decision.reward_r, 0.5)
        self.assertGreater(decision.expected_value_r, 0)

    def test_high_win_rate_with_negative_ev_is_rejected(self):
        decision = self.engine.evaluate(
            RRCandidate(0.25, p_win=0.70, samples=100, cost_r=0.02, oos_stability=0.90)
        )
        self.assertFalse(decision.accepted)
        self.assertEqual(decision.reason, "NON_POSITIVE_EV")

    def test_costs_raise_breakeven_win_rate(self):
        no_cost = self.engine.breakeven_win_rate(0.5, 0.0)
        with_cost = self.engine.breakeven_win_rate(0.5, 0.05)
        self.assertGreater(with_cost, no_cost)

    def test_stop_cannot_be_widened_after_entry(self):
        state = PositionRiskState(initial_hard_stop_r=1.0, current_hard_stop_r=0.8, target_r=1.5)
        ok, reason = validate_stop_update(state, 0.6)
        self.assertTrue(ok)
        self.assertEqual(reason, "STOP_UPDATE_OK")
        ok, reason = validate_stop_update(state, 0.9)
        self.assertFalse(ok)
        self.assertEqual(reason, "CANNOT_REINCREASE_RISK")
        ok, reason = validate_stop_update(state, 1.2)
        self.assertFalse(ok)
        self.assertEqual(reason, "CANNOT_WIDEN_BEYOND_INITIAL_RISK")


if __name__ == "__main__":
    unittest.main()
