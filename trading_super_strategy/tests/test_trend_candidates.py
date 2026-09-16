from __future__ import annotations

from datetime import datetime, timedelta
import unittest

from trading_super_strategy.backtest_engine import Bar
from trading_super_strategy.registry_schema import StrategyDirection
from trading_super_strategy.trend_candidates import (
    R1_FROZEN_GRID,
    TrendRiskConfig,
    channel_breakout_signal,
    ma_crossover_signal,
    make_r1_runner,
    past_return_sign_signal,
    vol_scaled_trend_signal,
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


class TrendCandidateTests(unittest.TestCase):
    def test_frozen_grid_is_small_and_explicit(self):
        self.assertEqual(set(R1_FROZEN_GRID), {"past_return_sign", "ma_crossover", "channel_breakout", "vol_scaled_trend"})
        self.assertEqual(R1_FROZEN_GRID["past_return_sign"], (20, 60))
        self.assertEqual(R1_FROZEN_GRID["ma_crossover"], ((10, 30), (20, 60)))
        self.assertEqual(R1_FROZEN_GRID["channel_breakout"], (20, 55))
        self.assertEqual(R1_FROZEN_GRID["vol_scaled_trend"], ((20, 1.0), (60, 1.0)))

    def test_runner_rejects_parameter_outside_preregistered_grid(self):
        with self.assertRaises(ValueError):
            make_r1_runner(
                family="past_return_sign",
                direction=StrategyDirection.LONG,
                timeframe_minutes=15,
                parameters=37,
            )

    def test_channel_breakout_uses_prior_window_only(self):
        # 20 prior bars stay below 101.5; the final closed bar breaks above.
        closes = [100.0 + (i % 3) * 0.1 for i in range(21)] + [103.0]
        history = bars_from_closes(closes)
        fn = channel_breakout_signal(
            StrategyDirection.LONG,
            lookback=20,
            risk=TrendRiskConfig(atr_lookback=5),
        )
        intent = fn(history)
        self.assertIsNotNone(intent)
        self.assertGreater(intent.stop_distance, 0.0)
        self.assertGreater(intent.target_distance, 0.0)

    def test_signal_at_prefix_does_not_change_when_future_bar_is_appended(self):
        closes = [100.0 + (i % 3) * 0.1 for i in range(21)] + [103.0]
        prefix = bars_from_closes(closes)
        fn = channel_breakout_signal(
            StrategyDirection.LONG,
            lookback=20,
            risk=TrendRiskConfig(atr_lookback=5),
        )
        before = fn(prefix)
        self.assertIsNotNone(before)

        # Future crash is not visible to a signal evaluated on the saved prefix.
        future = Bar(
            timestamp=prefix[-1].timestamp + timedelta(minutes=15),
            open=103.0,
            high=103.25,
            low=89.0,
            close=90.0,
            volume=5000.0,
        )
        extended = prefix + [future]
        after_on_same_prefix = fn(extended[:-1])
        self.assertEqual(before, after_on_same_prefix)

    def test_ma_crossover_long_and_short_are_directionally_symmetric(self):
        risk = TrendRiskConfig(atr_lookback=3)
        # Use a small direct pair for unit mechanics; the runner factory still
        # rejects non-frozen production-research parameterizations.
        up = bars_from_closes([10, 10, 10, 10, 10, 10, 10, 10, 10, 12])
        down = bars_from_closes([10, 10, 10, 10, 10, 10, 10, 10, 10, 8])
        long_fn = ma_crossover_signal(StrategyDirection.LONG, 2, 5, risk)
        short_fn = ma_crossover_signal(StrategyDirection.SHORT, 2, 5, risk)
        self.assertIsNotNone(long_fn(up))
        self.assertIsNotNone(short_fn(down))

    def test_past_return_requires_transition_not_permanent_reentry(self):
        risk = TrendRiskConfig(atr_lookback=3)
        fn = past_return_sign_signal(StrategyDirection.LONG, lookback=3, risk=risk)
        # Strongly rising history already had a positive lookback return on the
        # prior bar, so it should not emit a fresh transition every bar.
        history = bars_from_closes([100, 101, 102, 103, 104, 105, 106])
        self.assertIsNone(fn(history))

    def test_vol_scaled_signal_waits_for_enough_closed_bars(self):
        fn = vol_scaled_trend_signal(
            StrategyDirection.LONG,
            lookback=20,
            threshold=1.0,
            risk=TrendRiskConfig(atr_lookback=5),
        )
        history = bars_from_closes([100 + i * 0.1 for i in range(15)])
        self.assertIsNone(fn(history))

    def test_factory_builds_long_short_independent_variants(self):
        long_runner = make_r1_runner(
            family="channel_breakout",
            direction=StrategyDirection.LONG,
            timeframe_minutes=15,
            parameters=20,
        )
        short_runner = make_r1_runner(
            family="channel_breakout",
            direction=StrategyDirection.SHORT,
            timeframe_minutes=15,
            parameters=20,
        )
        self.assertNotEqual(long_runner.runner_id, short_runner.runner_id)
        self.assertTrue(long_runner.runner_id.endswith(":LONG"))
        self.assertTrue(short_runner.runner_id.endswith(":SHORT"))


if __name__ == "__main__":
    unittest.main()
