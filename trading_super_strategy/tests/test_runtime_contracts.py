import unittest
from datetime import datetime, timedelta, timezone

from trading_super_strategy.macro_point_in_time import MacroRelease, PointInTimeMacroStore, Freshness, apply_macro_modifier
from trading_super_strategy.execution_gateway import DeterministicExecutionGateway, Decision, Mode, OrderState, LIVE_MONEY

UTC = timezone.utc


class MacroContractTests(unittest.TestCase):
    def test_future_release_is_not_visible(self):
        release = MacroRelease('CPI', datetime(2026, 9, 10, 8, 30, tzinfo=UTC), 2.8, 3.0)
        store = PointInTimeMacroStore([release])
        snap = store.snapshot('CPI', datetime(2026, 9, 10, 8, 29, tzinfo=UTC))
        self.assertEqual(snap.freshness, Freshness.MISSING)
        self.assertTrue(snap.veto)

    def test_revision_does_not_leak(self):
        release = MacroRelease('NFP', datetime(2026, 9, 4, 8, 30, tzinfo=UTC), 150.0, 140.0,
                               revision_time=datetime(2026, 10, 2, 8, 30, tzinfo=UTC), revised_value=175.0)
        store = PointInTimeMacroStore([release])
        snap = store.snapshot('NFP', datetime(2026, 9, 4, 9, 0, tzinfo=UTC))
        self.assertEqual(snap.actual, 140.0)
        self.assertEqual(snap.surprise, -10.0)

    def test_macro_is_modifier_and_veto(self):
        release = MacroRelease('FOMC', datetime(2026, 9, 9, 14, 0, tzinfo=UTC), 0.0, 0.2, severity=1.0)
        store = PointInTimeMacroStore([release])
        snap = store.snapshot('FOMC', datetime(2026, 9, 9, 14, 1, tzinfo=UTC))
        self.assertEqual(apply_macro_modifier(0.8, snap), 0.0)


class ExecutionGatewayTests(unittest.TestCase):
    def test_live_money_is_immutable_false(self):
        self.assertFalse(LIVE_MONEY)
        gateway = DeterministicExecutionGateway(mode=Mode.SIM)
        self.assertEqual(gateway.mode, Mode.SIM)

    def test_duplicate_is_blocked(self):
        gateway = DeterministicExecutionGateway()
        d = Decision('run1', 1, 'NQ', 'BUY', 1, 10.0)
        self.assertEqual(gateway.submit(d).state, OrderState.ACCEPTED)
        self.assertEqual(gateway.submit(d).state, OrderState.DUPLICATE)

    def test_data_unsafe_flattens_and_kills(self):
        gateway = DeterministicExecutionGateway()
        gateway.open_positions['NQ'] = 1
        d = Decision('run2', 2, 'NQ', 'SELL', 1, 10.0, data_safe=False)
        result = gateway.submit(d)
        self.assertEqual(result.state, OrderState.REJECTED)
        self.assertTrue(gateway.killed)
        self.assertEqual(gateway.open_positions, {})

    def test_hard_max_loss_flattens(self):
        gateway = DeterministicExecutionGateway(max_loss_r=2.0)
        gateway.open_positions['ES'] = 1
        gateway.apply_loss(2.0)
        self.assertTrue(gateway.killed)
        self.assertEqual(gateway.open_positions, {})


if __name__ == '__main__':
    unittest.main()
