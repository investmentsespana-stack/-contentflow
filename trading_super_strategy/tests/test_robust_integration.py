import unittest

from trading_super_strategy.robust_integration import SUPPORTED_RR, evaluate_returns


class RobustIntegrationTests(unittest.TestCase):
    def test_supported_rr_includes_sub_one(self):
        for rr in (0.25, 0.40, 0.50, 0.70, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0):
            self.assertIn(rr, SUPPORTED_RR)

    def test_negative_expectancy_fails_even_with_high_win_rate(self):
        # 80% wins at +0.25R still has <=0 net expectancy once losses/costs are included.
        returns = [0.25] * 24 + [-1.0] * 6
        result = evaluate_returns(returns, 0.25, execution_cost_r=0.03, tested_trials=20)
        self.assertFalse(result.passed)
        self.assertIn("non_positive_net_expectancy", result.reasons)

    def test_small_sample_fails_closed(self):
        result = evaluate_returns([1.0] * 10, 1.0, tested_trials=10)
        self.assertFalse(result.passed)
        self.assertIn("insufficient_sample", result.reasons)

    def test_unsupported_rr_rejected(self):
        with self.assertRaises(ValueError):
            evaluate_returns([1.0] * 40, 0.6)

    def test_metrics_are_deterministic(self):
        returns = [1.5, -1.0, 1.5, 1.5, -1.0] * 12
        a = evaluate_returns(returns, 1.5, tested_trials=50)
        b = evaluate_returns(returns, 1.5, tested_trials=50)
        self.assertEqual(a, b)


if __name__ == "__main__":
    unittest.main()
