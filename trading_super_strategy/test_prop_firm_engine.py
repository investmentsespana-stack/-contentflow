import unittest

from prop_firm_engine import PropFirmPolicyEngine, PropFirmProfile, TradeDay


class PropFirmPolicyEngineTests(unittest.TestCase):
    def setUp(self):
        self.engine = PropFirmPolicyEngine()

    def test_consistency_can_delay_payout_without_failing_account(self):
        profile = PropFirmProfile(
            profile_id="x",
            firm="Test",
            plan="Consistency",
            phase="funded",
            consistency_pct=0.40,
        )
        state, assessment = self.engine.simulate(
            50_000,
            (TradeDay(1000), TradeDay(500), TradeDay(500)),
            profile,
        )
        self.assertFalse(state.failed)
        self.assertAlmostEqual(assessment.consistency_ratio, 0.50)
        self.assertFalse(assessment.consistency_ok)
        self.assertFalse(assessment.payout_eligible)
        self.assertEqual(assessment.reason, "CONSISTENCY_NOT_MET")

    def test_more_even_profit_distribution_passes_consistency(self):
        profile = PropFirmProfile(
            profile_id="x",
            firm="Test",
            plan="Consistency",
            phase="funded",
            consistency_pct=0.40,
        )
        _, assessment = self.engine.simulate(
            50_000,
            (TradeDay(700), TradeDay(600), TradeDay(500), TradeDay(400)),
            profile,
        )
        self.assertTrue(assessment.consistency_ok)
        self.assertTrue(assessment.payout_eligible)

    def test_intraday_trailing_drawdown_breach_fails_closed(self):
        profile = PropFirmProfile(
            profile_id="x",
            firm="Test",
            plan="Trailing",
            phase="funded",
            max_loss_type="intraday_trailing",
            max_loss_distance=1000,
        )
        state, assessment = self.engine.simulate(
            50_000,
            (
                TradeDay(500, intraday_peak_equity=50_700, intraday_min_equity=49_600),
            ),
            profile,
        )
        self.assertTrue(state.failed)
        self.assertEqual(state.fail_reason, "MAX_LOSS_BREACH")
        self.assertFalse(assessment.survival_ok)

    def test_contract_limit_is_hard_failure(self):
        profile = PropFirmProfile(
            profile_id="x",
            firm="Test",
            plan="Limit",
            phase="funded",
            contract_limit=3,
        )
        state, _ = self.engine.simulate(50_000, (TradeDay(100, max_contracts_used=4),), profile)
        self.assertTrue(state.failed)
        self.assertEqual(state.fail_reason, "CONTRACT_LIMIT")

    def test_news_restriction_is_hard_failure(self):
        profile = PropFirmProfile(
            profile_id="x",
            firm="Test",
            plan="News",
            phase="funded",
            news_restricted=True,
        )
        state, _ = self.engine.simulate(50_000, (TradeDay(100, traded_restricted_news=True),), profile)
        self.assertTrue(state.failed)
        self.assertEqual(state.fail_reason, "NEWS_RESTRICTION")


if __name__ == "__main__":
    unittest.main()
