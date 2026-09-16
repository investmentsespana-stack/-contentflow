from __future__ import annotations

from datetime import datetime, timedelta
import unittest

from trading_super_strategy.backtest_engine import Bar
from trading_super_strategy.registry_schema import StrategyDirection
from trading_super_strategy.nq_vol_mean_reversion import (
    R3_FROZEN_PARAMETERS,
    R3_FROZEN_TIMEFRAMES,
    R3RiskConfig,
    make_r3_runner,
    nq_vol_conditioned_mean_reversion_signal,
    prior_window_zscore,
    realized_vol_ratio,
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


class NQVolMeanReversionTests(unittest.TestCase):
    def test_research_hypothesis_is_single_and_frozen(self):
        self.assertEqual(R3_FROZEN_PARAMETERS, (20, 10, 60, 1.25, 1.75))
        self.assertEqual(R3_FROZEN_TIMEFRAMES, (15,))

    def test_factory_rejects_parameter_or_timeframe_search(self):
        with self.assertRaises(ValueError):
            make_r3_runner(
                direction=StrategyDirection.LONG,
                timeframe_minutes=5,
            )
        with self.assertRaises(ValueError):
            make_r3_runner(
                direction=StrategyDirection.LONG,
                timeframe_minutes=15,
                parameters=(20, 10, 60, 1.10, 1.75),
            )

    def test_zscore_reference_excludes_current_bar(self):
        history = bars_from_closes([100, 101, 99, 101, 99, 101, 98.5])
        z = prior_window_zscore(history, 5)
        self.assertIsNotNone(z)
        self.assertLess(z, -1.5)

    def test_normal_volatility_allows_symmetric_long_short_excursions(self):
        risk = R3RiskConfig(atr_lookback=3)
        long_fn = nq_vol_conditioned_mean_reversion_signal(
            StrategyDirection.LONG,
            z_lookback=5,
            short_vol_lookback=3,
            long_vol_lookback=6,
            max_vol_ratio=1.50,
            z_threshold=1.50,
            risk=risk,
        )
        short_fn = nq_vol_conditioned_mean_reversion_signal(
            StrategyDirection.SHORT,
            z_lookback=5,
            short_vol_lookback=3,
            long_vol_lookback=6,
            max_vol_ratio=1.50,
            z_threshold=1.50,
            risk=risk,
        )
        long_history = bars_from_closes([100, 101, 99, 101, 99, 101, 99, 101, 98.5])
        short_history = bars_from_closes([100, 99, 101, 99, 101, 99, 101, 99, 101.5])
        self.assertIsNotNone(long_fn(long_history))
        self.assertIsNotNone(short_fn(short_history))

    def test_volatility_expansion_blocks_countertrend_entry(self):
        risk = R3RiskConfig(atr_lookback=3)
        history = bars_from_closes([100, 100.1, 100.2, 100.3, 100.4, 100.5, 105, 95, 90])
        ratio = realized_vol_ratio(
            history,
            short_lookback=3,
            long_lookback=6,
            exclude_current_bar=True,
        )
        self.assertIsNotNone(ratio)
        self.assertGreater(ratio, 1.0)

        fn = nq_vol_conditioned_mean_reversion_signal(
            StrategyDirection.LONG,
            z_lookback=5,
            short_vol_lookback=3,
            long_vol_lookback=6,
            max_vol_ratio=1.0,
            z_threshold=1.5,
            risk=risk,
        )
        self.assertIsNone(fn(history))

    def test_signal_uses_preexisting_volatility_state_not_signal_bar(self):
        stable_prefix = bars_from_closes([100, 101, 99, 101, 99, 101, 99, 101])
        normal_ratio = realized_vol_ratio(
            stable_prefix + [
                Bar(
                    timestamp=stable_prefix[-1].timestamp + timedelta(minutes=15),
                    open=101.0,
                    high=101.5,
                    low=98.0,
                    close=98.5,
                    volume=8000.0,
                )
            ],
            short_lookback=3,
            long_lookback=6,
            exclude_current_bar=True,
        )
        prefix_ratio = realized_vol_ratio(
            stable_prefix,
            short_lookback=3,
            long_lookback=6,
            exclude_current_bar=False,
        )
        self.assertAlmostEqual(normal_ratio, prefix_ratio, places=12)

    def test_future_bar_cannot_change_saved_prefix_signal(self):
        risk = R3RiskConfig(atr_lookback=3)
        fn = nq_vol_conditioned_mean_reversion_signal(
            StrategyDirection.LONG,
            z_lookback=5,
            short_vol_lookback=3,
            long_vol_lookback=6,
            max_vol_ratio=1.50,
            z_threshold=1.50,
            risk=risk,
        )
        prefix = bars_from_closes([100, 101, 99, 101, 99, 101, 99, 101, 98.5])
        before = fn(prefix)
        self.assertIsNotNone(before)
        future = Bar(
            timestamp=prefix[-1].timestamp + timedelta(minutes=15),
            open=98.5,
            high=120.0,
            low=70.0,
            close=118.0,
            volume=12000.0,
        )
        self.assertEqual(before, fn((prefix + [future])[:-1]))

    def test_factory_is_nq_only_and_directionally_independent(self):
        long_runner = make_r3_runner(
            direction=StrategyDirection.LONG,
            timeframe_minutes=15,
        )
        short_runner = make_r3_runner(
            direction=StrategyDirection.SHORT,
            timeframe_minutes=15,
        )
        self.assertEqual(long_runner.variant.identity.supported_instruments, ("NQ",))
        self.assertNotEqual(long_runner.runner_id, short_runner.runner_id)
        self.assertTrue(long_runner.runner_id.endswith(":LONG"))
        self.assertTrue(short_runner.runner_id.endswith(":SHORT"))
        self.assertEqual(long_runner.variant.lineage.origin, "ROBUST_STRATEGY_SCREEN_V1:R3")


if __name__ == "__main__":
    unittest.main()
