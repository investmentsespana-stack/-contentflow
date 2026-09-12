import unittest
from confirmation_engine import ConfirmationEngine


class ConfirmationEngineTests(unittest.TestCase):
    def setUp(self):
        self.engine = ConfirmationEngine(required=4)
        self.base = {
            "ny_9_12_context": True,
            "structure_liquidity": True,
            "flow_volume": True,
            "cross_market": True,
            "strategy_pool": False,
        }

    def test_four_of_five_is_candidate(self):
        result = self.engine.evaluate(self.base)
        self.assertTrue(result.candidate)
        self.assertFalse(result.vetoed)
        self.assertEqual(result.approved_blocks, 4)

    def test_macro_veto_blocks_candidate(self):
        result = self.engine.evaluate(self.base, macro_veto=True)
        self.assertFalse(result.candidate)
        self.assertTrue(result.vetoed)
        self.assertEqual(result.reason, "MACRO_VETO")

    def test_data_unsafe_fails_closed(self):
        result = self.engine.evaluate(self.base, data_healthy=False)
        self.assertFalse(result.candidate)
        self.assertTrue(result.vetoed)
        self.assertEqual(result.reason, "DATA_UNSAFE")


if __name__ == "__main__":
    unittest.main()
