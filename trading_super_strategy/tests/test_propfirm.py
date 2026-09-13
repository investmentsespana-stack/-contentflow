from __future__ import annotations

import unittest

from trading_super_strategy.propfirm import (
    AccountState,
    BreachReason,
    DailyRolloverEvent,
    DrawdownKind,
    DrawdownRule,
    Limit,
    NewsWindow,
    PayoutEvent,
    PayoutRule,
    PropFirmPolicy,
    RuleUnit,
    TradeEvent,
    VerificationState,
    apply_event,
    evaluate_candidate,
    payout_eligible,
)


def policy(**overrides) -> PropFirmPolicy:
    base = dict(
        policy_id="verified-test-profile",
        verification_state=VerificationState.VERIFIED,
        reverify_required=False,
        drawdown_rules=(
            DrawdownRule(DrawdownKind.STATIC, Limit(RuleUnit.ABSOLUTE, 2_000)),
            DrawdownRule(DrawdownKind.TRAILING, Limit(RuleUnit.ABSOLUTE, 1_500)),
        ),
        daily_loss_limit=Limit(RuleUnit.ABSOLUTE, 1_000),
        max_contracts=3,
        max_largest_profitable_day_pct=60.0,
        consistency_is_breach=False,
        payout_rule=PayoutRule(
            minimum_cycle_profit=1_000,
            payout_rate=0.5,
            retained_buffer=500,
        ),
        news_windows=(),
    )
    base.update(overrides)
    return PropFirmPolicy(**base)


class PropFirmCertificationTests(unittest.TestCase):
    def test_unverified_and_stale_fail_closed(self) -> None:
        for state in (VerificationState.UNKNOWN, VerificationState.STALE):
            p = policy(verification_state=state)
            s = apply_event(p, AccountState.fresh(50_000), TradeEvent(1, "NQ", 100, 0))
            self.assertEqual(s.breach, BreachReason.POLICY_UNVERIFIED)
        p = policy(reverify_required=True)
        s = apply_event(p, AccountState.fresh(50_000), TradeEvent(1, "NQ", 100, 0))
        self.assertEqual(s.breach, BreachReason.POLICY_UNVERIFIED)

    def test_static_drawdown_breach(self) -> None:
        p = policy(
            drawdown_rules=(
                DrawdownRule(DrawdownKind.STATIC, Limit(RuleUnit.ABSOLUTE, 500)),
            ),
            daily_loss_limit=None,
        )
        s = apply_event(p, AccountState.fresh(50_000), TradeEvent(1, "NQ", -600, 0))
        self.assertEqual(s.breach, BreachReason.STATIC_DRAWDOWN)

    def test_trailing_drawdown_breach(self) -> None:
        p = policy(
            drawdown_rules=(
                DrawdownRule(DrawdownKind.TRAILING, Limit(RuleUnit.ABSOLUTE, 500)),
            ),
            daily_loss_limit=None,
        )
        s = AccountState.fresh(50_000)
        s = apply_event(p, s, TradeEvent(1, "NQ", 1_000, 0))
        self.assertIsNone(s.breach)
        s = apply_event(p, s, TradeEvent(2, "NQ", -600, 0))
        self.assertEqual(s.breach, BreachReason.TRAILING_DRAWDOWN)

    def test_daily_loss_breach(self) -> None:
        p = policy(drawdown_rules=(), daily_loss_limit=Limit(RuleUnit.ABSOLUTE, 300))
        s = apply_event(p, AccountState.fresh(50_000), TradeEvent(1, "NQ", -350, 0))
        self.assertEqual(s.breach, BreachReason.DAILY_LOSS)

    def test_contract_limit_breach(self) -> None:
        p = policy(drawdown_rules=(), daily_loss_limit=None, max_contracts=2)
        s = apply_event(p, AccountState.fresh(50_000), TradeEvent(1, "NQ", 0, 3))
        self.assertEqual(s.breach, BreachReason.CONTRACT_LIMIT)

    def test_consistency_can_be_hard_breach_or_payout_gate(self) -> None:
        hard = policy(
            drawdown_rules=(),
            daily_loss_limit=None,
            max_largest_profitable_day_pct=50.0,
            consistency_is_breach=True,
        )
        s = apply_event(hard, AccountState.fresh(50_000), TradeEvent(1, "NQ", 1_000, 0))
        self.assertEqual(s.breach, BreachReason.CONSISTENCY_CONCENTRATION)

        gate = policy(
            drawdown_rules=(),
            daily_loss_limit=None,
            max_largest_profitable_day_pct=50.0,
            consistency_is_breach=False,
            payout_rule=PayoutRule(500, 0.5, 0),
        )
        s = apply_event(gate, AccountState.fresh(50_000), TradeEvent(1, "NQ", 1_000, 0))
        self.assertIsNone(s.breach)
        self.assertFalse(payout_eligible(gate, s))

    def test_news_restriction_breach(self) -> None:
        p = policy(
            drawdown_rules=(),
            daily_loss_limit=None,
            news_windows=(NewsWindow(100, 200, ("NQ",)),),
        )
        s = apply_event(p, AccountState.fresh(50_000), TradeEvent(150, "NQ", 0, 0))
        self.assertEqual(s.breach, BreachReason.NEWS_RESTRICTION)

    def test_payout_eligibility_and_reset(self) -> None:
        p = policy(
            drawdown_rules=(),
            daily_loss_limit=None,
            max_largest_profitable_day_pct=None,
            payout_rule=PayoutRule(1_000, 0.5, 500),
        )
        s = AccountState.fresh(50_000)
        s = apply_event(p, s, TradeEvent(1, "NQ", 1_200, 0))
        self.assertTrue(payout_eligible(p, s))
        s = apply_event(p, s, PayoutEvent(2, 500))
        self.assertIsNone(s.breach)
        self.assertFalse(s.payout_eligible)
        self.assertEqual(s.cycle_profit, 700)

    def test_breach_is_terminal_and_payout_cannot_clear_it(self) -> None:
        p = policy(drawdown_rules=(), daily_loss_limit=None, max_contracts=1)
        s = apply_event(p, AccountState.fresh(50_000), TradeEvent(1, "NQ", 0, 2))
        self.assertEqual(s.breach, BreachReason.CONTRACT_LIMIT)
        s2 = apply_event(p, s, PayoutEvent(2, 100))
        self.assertEqual(s2, s)

    def test_daily_rollover_preserves_largest_profitable_day(self) -> None:
        p = policy(drawdown_rules=(), daily_loss_limit=None)
        s = AccountState.fresh(50_000)
        s = apply_event(p, s, TradeEvent(1, "NQ", 400, 0))
        s = apply_event(p, s, DailyRolloverEvent(2))
        self.assertEqual(s.largest_profitable_day, 400)
        self.assertEqual(s.daily_pnl, 0)

    def test_negative_oos_ev_is_rejected(self) -> None:
        p = policy(
            drawdown_rules=(),
            daily_loss_limit=None,
            max_contracts=None,
            max_largest_profitable_day_pct=None,
            payout_rule=PayoutRule(100, 0.5, 0),
        )
        result = evaluate_candidate(
            p,
            [-1.0, -1.0, 0.2, 0.2],
            initial_balance=50_000,
            risk_per_trade=100,
            cost_r=0.02,
            samples=100,
        )
        self.assertLessEqual(result.net_oos_ev_r, 0)
        self.assertFalse(result.accepted)

    def test_negative_rr_candidate_can_pass_only_on_positive_ev_and_survival(self) -> None:
        p = policy(
            drawdown_rules=(
                DrawdownRule(DrawdownKind.STATIC, Limit(RuleUnit.ABSOLUTE, 5_000)),
            ),
            daily_loss_limit=None,
            max_contracts=None,
            max_largest_profitable_day_pct=None,
            payout_rule=PayoutRule(200, 0.5, 0),
        )
        # Reward:risk = 0.5:1, but 90% empirical wins => positive expectancy.
        observations = [0.5] * 18 + [-1.0] * 2
        result = evaluate_candidate(
            p,
            observations,
            initial_balance=50_000,
            risk_per_trade=100,
            cost_r=0.01,
            samples=300,
            seed=11,
            minimum_survival=0.90,
            minimum_payout_probability=0.05,
        )
        self.assertGreater(result.net_oos_ev_r, 0)
        self.assertGreaterEqual(result.survival_probability, 0.90)
        self.assertTrue(result.accepted)


if __name__ == "__main__":
    unittest.main()
