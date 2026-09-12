import unittest

from robustness_engine import (
    MonteCarloConfig,
    MonteCarloRobustnessEngine,
    dropout_sensitivity,
    max_drawdown_r,
    walk_forward_stability,
)


class RobustnessEngineTests(unittest.TestCase):
    def test_max_drawdown(self):
        self.assertAlmostEqual(max_drawdown_r([1.0, -0.5, -1.0, 0.25]), 1.5)

    def test_monte_carlo_positive_edge_is_reproducible_with_seed(self):
        returns = [0.5, 0.4, -0.2, 0.3, -0.1] * 20
        engine = MonteCarloRobustnessEngine()
        cfg = MonteCarloConfig(iterations=300, seed=11, slippage_r_std=0.0, omit_trade_probability=0.0)
        a = engine.run(returns, cfg)
        b = engine.run(returns, cfg)
        self.assertEqual(a, b)
        self.assertGreater(a.profitable_probability, 0.90)
        self.assertGreater(a.median_total_r, 0)

    def test_cost_stress_reduces_performance(self):
        returns = [0.20, 0.15, -0.10, 0.18, -0.05] * 30
        engine = MonteCarloRobustnessEngine()
        base = engine.run(returns, MonteCarloConfig(iterations=250, seed=3, slippage_r_std=0.0, extra_cost_r=0.0))
        stressed = engine.run(returns, MonteCarloConfig(iterations=250, seed=3, slippage_r_std=0.0, extra_cost_r=0.10))
        self.assertLess(stressed.median_total_r, base.median_total_r)

    def test_walk_forward_requires_broad_stability(self):
        result = walk_forward_stability([0.2, 0.1, -0.05, 0.2] * 8, window_size=4)
        self.assertEqual(result.windows, 8)
        self.assertEqual(result.positive_window_rate, 1.0)
        self.assertGreater(result.stability_score, 0)

    def test_dropout_sensitivity_flags_fragility(self):
        full = [0.5, 0.5, 0.5, 0.5]
        reduced = [0.1, 0.1, 0.1, 0.1]
        self.assertGreater(dropout_sensitivity(full, reduced), 0.70)


if __name__ == "__main__":
    unittest.main()
