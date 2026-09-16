from __future__ import annotations

from datetime import datetime, timedelta
import unittest

from trading_super_strategy.backtest_engine import Bar
from trading_super_strategy.registry_schema import StrategyDirection
from trading_super_strategy.regime_switch_candidates import (
    R2_FROZEN_GRID,
    R2Mode,
    R2RiskConfig,
    classify_r2_regime,
    make_r2_runner,
    regime_switch_signal,
)


def bars_from_closes(closes):
    start = datetime(2026, 1, 2, 9, 30)
    out = []
    previous = closes[0]
    for i, close in enumerate(closes):
        open_ = previous if i else close
        high = max(open_, close) + 0.5
        low = min(open_, close) - 0.5
        out.append(
            Bar(
                timestamp=start + timedelta(minutes=15 * i),
                open=float(open_),
                high=float(high),
                low=float(low),
                close=float(close),
                volume=1000.0,
            )
        )
        previous = close
    return out


class RegimeSwitchCandidateTests(unittest.TestCase):
    def test_frozen_grid_is_deliberately_small(self):
        self.assertEqual(set(R2_FROZEN_GRID), {"er_switch"})
        self.assertEqual(
            R2_FROZEN_GRID["er_switch"],
            (
                (20, 20, 0.60, 0.25, 1.50),
                (60, 20, 0.60, 0.25, 1.50),
            ),
        )

    def test_runner_rejects_unregistered_parameter_search(self):
        with self.assertRaises(ValueError):
            make_r2_runner(
                direction=StrategyDirection.LONG,
                timeframe_minutes=15,
                parameters=(37, 17, 0.57, 0.22, 1.37),
            )

    def test_classifier_has_trend_range_and_no_trade_states(self):
        trending = bars_from_closes([100 + i for i in range(12)])
        trend_state = classify_r2_regime(
            trending,
            trend_lookback=10,
            range_lookback=5,
            trend_er=0.60,
            range_er=0.25,
        )
        self.assertIsNotNone(trend_state)
        self.assertEqual(trend_state.mode, R2Mode.TREND)

        ranging = bars_from_closes([100, 101, 99, 101, 99, 101, 99, 101, 99, 101, 100])
        range_state = classify_r2_regime(
            ranging,
            trend_lookback=10,
            range_lookback=5,
            trend_er=0.60,
            range_er=0.25,
        )
        self.assertIsNotNone(range_state)
        self.assertEqual(range_state.mode, R2Mode.MEAN_REVERSION)

        # Ten one-point moves with net +4 => ER=0.40, inside abstention gap.
        deadband = bars_from_closes([100, 101, 102, 101, 102, 103, 104, 103, 104, 105, 104])
        no_trade = classify_r2_regime(
            deadband,
            trend_lookback=10,
            range_lookback=5,
            trend_er=0.60,
            range_er=0.25,
        )
        self.assertIsNotNone(no_trade)
        self.assertEqual(no_trade.mode, R2Mode.NO_TRADE)

    def test_trend_transition_routes_long_and_short_symmetrically(self):
        risk = R2RiskConfig(atr_lookback=3)
        long_fn = regime_switch_signal(
            StrategyDirection.LONG,
            trend_lookback=5,
            range_lookback=5,
            trend_er=0.60,
            range_er=0.25,
            mean_reversion_z=1.50,
            risk=risk,
        )
        short_fn = regime_switch_signal(
            StrategyDirection.SHORT,
            trend_lookback=5,
            range_lookback=5,
            trend_er=0.60,
            range_er=0.25,
            mean_reversion_z=1.50,
            risk=risk,
        )
        # Previous 5-move ER=.20; current ER=.60 after the final directional bar.
        up = bars_from_closes([100, 99, 100, 101, 100, 101, 102])
        down = bars_from_closes([100, 101, 100, 99, 100, 99, 98])
        self.assertIsNotNone(long_fn(up))
        self.assertIsNotNone(short_fn(down))

    def test_mean_reversion_routes_first_extreme_only(self):
        risk = R2RiskConfig(atr_lookback=3)
        long_fn = regime_switch_signal(
            StrategyDirection.LONG,
            trend_lookback=5,
            range_lookback=5,
            trend_er=0.60,
            range_er=0.25,
            mean_reversion_z=1.50,
            risk=risk,
        )
        short_fn = regime_switch_signal(
            StrategyDirection.SHORT,
            trend_lookback=5,
            range_lookback=5,
            trend_er=0.60,
            range_er=0.25,
            mean_reversion_z=1.50,
            risk=risk,
        )
        long_extreme = bars_from_closes([100, 101, 99, 101, 99, 101, 98.5])
        short_extreme = bars_from_closes([100, 99, 101, 99, 101, 99, 101.5])
        self.assertIsNotNone(long_fn(long_extreme))
        self.assertIsNotNone(short_fn(short_extreme))

    def test_no_trade_deadband_emits_no_signal(self):
        risk = R2RiskConfig(atr_lookback=3)
        fn = regime_switch_signal(
            StrategyDirection.LONG,
            trend_lookback=10,
            range_lookback=5,
            trend_er=0.60,
            range_er=0.25,
            mean_reversion_z=1.50,
            risk=risk,
        )
        deadband = bars_from_closes([100, 101, 102, 101, 102, 103, 104, 103, 104, 105, 104, 105])
        self.assertIsNone(fn(deadband))

    def test_future_bar_cannot_change_saved_prefix_signal(self):
        risk = R2RiskConfig(atr_lookback=3)
        fn = regime_switch_signal(
            StrategyDirection.LONG,
            trend_lookback=5,
            range_lookback=5,
            trend_er=0.60,
            range_er=0.25,
            mean_reversion_z=1.50,
            risk=risk,
        )
        prefix = bars_from_closes([100, 99, 100, 101, 100, 101, 102])
        before = fn(prefix)
        self.assertIsNotNone(before)
        future = Bar(
            timestamp=prefix[-1].timestamp + timedelta(minutes=15),
            open=102.0,
            high=103.0,
            low=80.0,
            close=82.0,
            volume=9000.0,
        )
        extended = prefix + [future]
        self.assertEqual(before, fn(extended[:-1]))

    def test_factory_builds_independent_directional_variants(self):
        params = R2_FROZEN_GRID["er_switch"][0]
        long_runner = make_r2_runner(
            direction=StrategyDirection.LONG,
            timeframe_minutes=15,
            parameters=params,
        )
        short_runner = make_r2_runner(
            direction=StrategyDirection.SHORT,
            timeframe_minutes=15,
            parameters=params,
        )
        self.assertNotEqual(long_runner.runner_id, short_runner.runner_id)
        self.assertTrue(long_runner.runner_id.endswith(":LONG"))
        self.assertTrue(short_runner.runner_id.endswith(":SHORT"))
        self.assertEqual(long_runner.variant.lineage.origin, "ROBUST_STRATEGY_SCREEN_V1:R2")


if __name__ == "__main__":
    unittest.main()
