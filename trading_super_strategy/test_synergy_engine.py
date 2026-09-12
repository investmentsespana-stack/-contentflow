import unittest
from synergy_engine import PairCompatibility, StrategyState, StrategySynergyEngine


class StrategySynergyEngineTests(unittest.TestCase):
    def setUp(self):
        self.engine = StrategySynergyEngine()
        self.a = StrategyState("breakout", "breakout", 1, 0.80, 0.68, 0.35, 1.55, 6.0, 0.82, 1.5)
        self.b = StrategyState("orderflow", "order_flow", 1, 0.76, 0.71, 0.31, 1.48, 5.5, 0.85, 1.2)
        self.c = StrategyState("momentum", "momentum", 1, 0.72, 0.64, 0.28, 1.42, 6.5, 0.79, 1.8)
        self.short = StrategyState("meanrev", "mean_reversion", -1, 0.78, 0.70, 0.30, 1.50, 5.0, 0.83, 0.7)

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
            tuple(sorted(("breakout", "orderflow"))): self.pair("breakout", "orderflow"),
            tuple(sorted(("breakout", "momentum"))): self.pair("breakout", "momentum"),
            tuple(sorted(("orderflow", "momentum"))): self.pair("orderflow", "momentum"),
        }
        result = self.engine.evaluate([self.a, self.b, self.c], pairs)
        self.assertTrue(result.accepted)
        self.assertEqual(result.direction, 1)
        self.assertGreater(result.coordinated_target_seed_r, 0)

    def test_opposite_direction_is_rejected(self):
        pairs = {
            tuple(sorted(("breakout", "meanrev"))): self.pair("breakout", "meanrev")
        }
        result = self.engine.evaluate([self.a, self.short], pairs)
        self.assertFalse(result.accepted)
        self.assertEqual(result.reason, "DIRECTION_CONFLICT")

    def test_principle_conflict_is_rejected(self):
        pairs = {
            tuple(sorted(("breakout", "orderflow"))): self.pair(
                "breakout", "orderflow", principle_compatible=False
            )
        }
        result = self.engine.evaluate([self.a, self.b], pairs)
        self.assertFalse(result.accepted)
        self.assertTrue(result.reason.startswith("PRINCIPLE_CONFLICT"))

    def test_redundant_error_pattern_is_rejected(self):
        pairs = {
            tuple(sorted(("breakout", "orderflow"))): self.pair(
                "breakout", "orderflow", error_correlation=0.95
            )
        }
        result = self.engine.evaluate([self.a, self.b], pairs)
        self.assertFalse(result.accepted)
        self.assertTrue(result.reason.startswith("REDUNDANT_ERRORS"))

    def test_search_returns_best_valid_coalition(self):
        pairs = {
            tuple(sorted(("breakout", "orderflow"))): self.pair("breakout", "orderflow"),
            tuple(sorted(("breakout", "momentum"))): self.pair("breakout", "momentum"),
            tuple(sorted(("orderflow", "momentum"))): self.pair("orderflow", "momentum"),
        }
        result = self.engine.search_best([self.a, self.b, self.c], pairs, max_members=3)
        self.assertTrue(result.accepted)
        self.assertGreaterEqual(len(result.members), 2)


if __name__ == "__main__":
    unittest.main()
