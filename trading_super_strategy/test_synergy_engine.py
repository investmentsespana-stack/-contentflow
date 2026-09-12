import unittest
from synergy_engine import PairCompatibility, StrategyState, StrategySynergyEngine


class StrategySynergyEngineTests(unittest.TestCase):
    def setUp(self):
        self.engine = StrategySynergyEngine()
        self.a = StrategyState("breakout_long", "breakout", 1, 0.80, 0.68, 0.35, 1.55, 6.0, 0.82, 1.5)
        self.b = StrategyState("orderflow_long", "order_flow", 1, 0.76, 0.71, 0.31, 1.48, 5.5, 0.85, 1.2)
        self.c = StrategyState("momentum_long", "momentum", 1, 0.72, 0.64, 0.28, 1.42, 6.5, 0.79, 1.8)
        self.s1 = StrategyState("breakdown_short", "breakout", -1, 0.82, 0.73, 0.38, 1.62, 5.2, 0.86, 1.4)
        self.s2 = StrategyState("orderflow_short", "order_flow", -1, 0.79, 0.75, 0.36, 1.58, 4.9, 0.88, 1.1)

    @staticmethod
    def pair(a, b, **kwargs):
        values = {
            "principle_compatible": True,
            "error_correlation": 0.35,
            "contradiction_rate": 0.10,
            "target_overlap": 0.75,
        }
        values.update(kwargs)
        return PairCompatibility(a, b, **values)

    def test_compatible_coalition_is_accepted(self):
        pairs = {
            tuple(sorted(("breakout_long", "orderflow_long"))): self.pair("breakout_long", "orderflow_long"),
            tuple(sorted(("breakout_long", "momentum_long"))): self.pair("breakout_long", "momentum_long"),
            tuple(sorted(("orderflow_long", "momentum_long"))): self.pair("orderflow_long", "momentum_long"),
        }
        result = self.engine.evaluate([self.a, self.b, self.c], pairs)
        self.assertTrue(result.accepted)
        self.assertEqual(result.direction, 1)
        self.assertGreater(result.coordinated_target_seed_r, 0)

    def test_opposite_direction_is_rejected(self):
        pairs = {
            tuple(sorted(("breakout_long", "breakdown_short"))): self.pair("breakout_long", "breakdown_short")
        }
        result = self.engine.evaluate([self.a, self.s1], pairs)
        self.assertFalse(result.accepted)
        self.assertEqual(result.reason, "DIRECTION_CONFLICT")

    def test_principle_conflict_is_rejected(self):
        pairs = {
            tuple(sorted(("breakout_long", "orderflow_long"))): self.pair(
                "breakout_long", "orderflow_long", principle_compatible=False
            )
        }
        result = self.engine.evaluate([self.a, self.b], pairs)
        self.assertFalse(result.accepted)
        self.assertTrue(result.reason.startswith("PRINCIPLE_CONFLICT"))

    def test_redundant_error_pattern_is_rejected(self):
        pairs = {
            tuple(sorted(("breakout_long", "orderflow_long"))): self.pair(
                "breakout_long", "orderflow_long", error_correlation=0.95
            )
        }
        result = self.engine.evaluate([self.a, self.b], pairs)
        self.assertFalse(result.accepted)
        self.assertTrue(result.reason.startswith("REDUNDANT_ERRORS"))

    def test_search_returns_best_valid_coalition(self):
        pairs = {
            tuple(sorted(("breakout_long", "orderflow_long"))): self.pair("breakout_long", "orderflow_long"),
            tuple(sorted(("breakout_long", "momentum_long"))): self.pair("breakout_long", "momentum_long"),
            tuple(sorted(("orderflow_long", "momentum_long"))): self.pair("orderflow_long", "momentum_long"),
        }
        result = self.engine.search_best([self.a, self.b, self.c], pairs, max_members=3)
        self.assertTrue(result.accepted)
        self.assertGreaterEqual(len(result.members), 2)

    def test_searches_long_and_short_groups_independently(self):
        pairs = {
            tuple(sorted(("breakout_long", "orderflow_long"))): self.pair("breakout_long", "orderflow_long"),
            tuple(sorted(("breakout_long", "momentum_long"))): self.pair("breakout_long", "momentum_long"),
            tuple(sorted(("orderflow_long", "momentum_long"))): self.pair("orderflow_long", "momentum_long"),
            tuple(sorted(("breakdown_short", "orderflow_short"))): self.pair("breakdown_short", "orderflow_short"),
        }
        result = self.engine.search_best_by_direction([self.a, self.b, self.c, self.s1, self.s2], pairs, max_members=3)
        self.assertTrue(result[1].accepted)
        self.assertTrue(result[-1].accepted)
        self.assertEqual(result[1].direction, 1)
        self.assertEqual(result[-1].direction, -1)
        self.assertNotEqual(set(result[1].members), set(result[-1].members))

    def test_bullish_routes_long_bearish_routes_short_sideways_no_trade(self):
        pairs = {
            tuple(sorted(("breakout_long", "orderflow_long"))): self.pair("breakout_long", "orderflow_long"),
            tuple(sorted(("breakout_long", "momentum_long"))): self.pair("breakout_long", "momentum_long"),
            tuple(sorted(("orderflow_long", "momentum_long"))): self.pair("orderflow_long", "momentum_long"),
            tuple(sorted(("breakdown_short", "orderflow_short"))): self.pair("breakdown_short", "orderflow_short"),
        }
        directional = self.engine.search_best_by_direction([self.a, self.b, self.c, self.s1, self.s2], pairs, max_members=3)
        self.assertEqual(self.engine.route_for_regime("bullish", directional).action, "LONG")
        self.assertEqual(self.engine.route_for_regime("bearish", directional).action, "SHORT")
        self.assertEqual(self.engine.route_for_regime("sideways", directional).action, "NO_TRADE")
        self.assertEqual(self.engine.route_for_regime("unclear", directional).action, "NO_TRADE")


if __name__ == "__main__":
    unittest.main()
