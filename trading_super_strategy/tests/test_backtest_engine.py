from __future__ import annotations

from datetime import datetime, timedelta, timezone
import unittest

from trading_super_strategy.backtest_engine import (
    AmbiguousBarPolicy,
    BacktestConfig,
    Bar,
    CausalBacktestEngine,
    SignalIntent,
    StrategyRunner,
    TrialStatus,
)
from trading_super_strategy.registry_schema import (
    DataRequirement,
    DataRequirementType,
    HorizonUnit,
    LineageMetadata,
    StrategyDirection,
    StrategyIdentity,
    StrategyRegime,
    StrategyVariant,
    TradingHorizon,
    TradingPremise,
)


def make_variant(direction: StrategyDirection, canonical_id: str) -> StrategyVariant:
    return StrategyVariant(
        identity=StrategyIdentity(
            family_id="TEST_FAMILY",
            canonical_id=canonical_id,
            display_name=f"{canonical_id} {direction.value}",
            version="1.0.0",
            supported_instruments=("NQ",),
        ),
        direction=direction,
        premise=TradingPremise(
            premise="deterministic test premise",
            entry_rules="test signal",
            exit_rules="fixed stop/target",
            risk_rules="fixed quantity",
        ),
        regimes=(StrategyRegime.TRENDING_UP,),
        horizon=TradingHorizon(HorizonUnit.MINUTE, 1),
        data_requirements=(
            DataRequirement(
                DataRequirementType.PRICE_BAR,
                TradingHorizon(HorizonUnit.MINUTE, 2),
                1.0,
            ),
        ),
        lineage=LineageMetadata(origin="UNIT_TEST"),
    )


def make_bars(rows):
    base = datetime(2026, 1, 2, 14, 30, tzinfo=timezone.utc)
    return tuple(
        Bar(
            timestamp=base + timedelta(minutes=i),
            open=row[0],
            high=row[1],
            low=row[2],
            close=row[3],
            volume=100 + i,
        )
        for i, row in enumerate(rows)
    )


class BacktestEngineTests(unittest.TestCase):
    def test_signal_is_causal_and_enters_next_bar_open(self):
        bars = make_bars(
            [
                (100, 101, 99, 100),
                (105, 108, 104, 107),
                (107, 109, 106, 108),
            ]
        )
        seen_history_lengths = []

        def signal(history):
            seen_history_lengths.append(len(history))
            if len(history) == 1:
                return SignalIntent(quantity=1, stop_distance=5, target_distance=2)
            return None

        runner = StrategyRunner(make_variant(StrategyDirection.LONG, "CAUSAL"), signal)
        engine = CausalBacktestEngine(
            BacktestConfig(
                commission_per_unit_per_side=0.0,
                slippage_per_unit_per_side=0.25,
                min_completed_trades=1,
            )
        )
        result = engine.run({"NQ": bars}, [runner])
        trial = result.trials[0]

        self.assertEqual(seen_history_lengths, [1, 2, 3])
        self.assertEqual(trial.signal_time, bars[0].timestamp)
        self.assertEqual(trial.entry_time, bars[1].timestamp)
        self.assertEqual(trial.entry_price, 105.25)
        self.assertEqual(trial.status, TrialStatus.TARGET)
        self.assertGreater(trial.net_pnl, 0)

    def test_long_short_variants_are_scored_separately(self):
        bars = make_bars(
            [
                (100, 101, 99, 100),
                (100, 104, 96, 102),
                (102, 103, 101, 102),
            ]
        )

        def once(history):
            if len(history) == 1:
                return SignalIntent(quantity=1, stop_distance=3, target_distance=3)
            return None

        long_runner = StrategyRunner(make_variant(StrategyDirection.LONG, "SIDE"), once)
        short_runner = StrategyRunner(make_variant(StrategyDirection.SHORT, "SIDE"), once)
        engine = CausalBacktestEngine(BacktestConfig(min_completed_trades=1))
        result = engine.run({"NQ": bars}, [long_runner, short_runner])

        self.assertIn("SIDE:LONG", result.metrics)
        self.assertIn("SIDE:SHORT", result.metrics)
        self.assertEqual(result.metrics["SIDE:LONG"].completed_trades, 1)
        self.assertEqual(result.metrics["SIDE:SHORT"].completed_trades, 1)
        # Both stop and target are touched on the entry bar. STOP_FIRST is
        # conservative, so both directional variants must lose independently.
        self.assertLess(result.metrics["SIDE:LONG"].net_pnl, 0)
        self.assertLess(result.metrics["SIDE:SHORT"].net_pnl, 0)

    def test_costs_and_slippage_are_applied_once(self):
        bars = make_bars(
            [
                (100, 100.5, 99.5, 100),
                (100, 103, 99.5, 102),
                (102, 102, 102, 102),
            ]
        )

        def signal(history):
            return SignalIntent(quantity=2, stop_distance=5, target_distance=2) if len(history) == 1 else None

        runner = StrategyRunner(make_variant(StrategyDirection.LONG, "COST"), signal)
        engine = CausalBacktestEngine(
            BacktestConfig(
                commission_per_unit_per_side=0.50,
                slippage_per_unit_per_side=0.25,
                min_completed_trades=1,
            )
        )
        result = engine.run({"NQ": bars}, [runner])
        trial = result.trials[0]
        self.assertEqual(trial.status, TrialStatus.TARGET)
        self.assertAlmostEqual(trial.total_costs, 3.0)
        # Entry 100.25, target raw 102.25, exit after adverse slippage 102.00.
        # Price PnL = 1.75 * 2 = 3.50, commissions = 2.00 => net 1.50.
        self.assertAlmostEqual(trial.net_pnl, 1.50)

    def test_ambiguous_bar_can_require_finer_data(self):
        bars = make_bars(
            [
                (100, 101, 99, 100),
                (100, 106, 94, 100),
            ]
        )

        def signal(history):
            return SignalIntent(quantity=1, stop_distance=5, target_distance=5) if len(history) == 1 else None

        runner = StrategyRunner(make_variant(StrategyDirection.LONG, "AMB"), signal)
        engine = CausalBacktestEngine(
            BacktestConfig(
                min_completed_trades=1,
                ambiguous_bar_policy=AmbiguousBarPolicy.REQUIRE_FINER_DATA,
            )
        )
        result = engine.run({"NQ": bars}, [runner])
        trial = result.trials[0]
        self.assertEqual(trial.status, TrialStatus.FAILED_AMBIGUOUS_BAR)
        self.assertIsNone(trial.net_pnl)
        self.assertFalse(result.metrics[runner.runner_id].eligible)

    def test_last_bar_signal_is_recorded_as_failed_trial(self):
        bars = make_bars([(100, 101, 99, 100), (101, 102, 100, 101)])

        def signal(history):
            if len(history) == 2:
                return SignalIntent(quantity=1, stop_distance=1, target_distance=1)
            return None

        runner = StrategyRunner(make_variant(StrategyDirection.LONG, "LAST"), signal)
        result = CausalBacktestEngine(BacktestConfig(min_completed_trades=1)).run({"NQ": bars}, [runner])
        self.assertEqual(result.trials[0].status, TrialStatus.FAILED_NO_NEXT_BAR)
        self.assertEqual(result.metrics[runner.runner_id].attempts, 1)
        self.assertEqual(result.metrics[runner.runner_id].failed_trials, 1)

    def test_sample_size_gate_does_not_rewrite_trial_outcomes(self):
        bars = make_bars([(100, 101, 99, 100), (100, 104, 99, 103)])

        def signal(history):
            return SignalIntent(quantity=1, stop_distance=5, target_distance=2) if len(history) == 1 else None

        runner = StrategyRunner(make_variant(StrategyDirection.LONG, "SAMPLE"), signal)
        result = CausalBacktestEngine(BacktestConfig(min_completed_trades=2)).run({"NQ": bars}, [runner])
        metrics = result.metrics[runner.runner_id]
        self.assertEqual(result.trials[0].status, TrialStatus.TARGET)
        self.assertEqual(metrics.completed_trades, 1)
        self.assertFalse(metrics.eligible)
        self.assertEqual(metrics.eligibility_reason, "sample_size<2")

    def test_data_unsafe_entry_fails_closed(self):
        base = datetime(2026, 1, 2, 14, 30, tzinfo=timezone.utc)
        bars = (
            Bar(base, 100, 101, 99, 100, 10, True),
            Bar(base + timedelta(minutes=1), 100, 101, 99, 100, 10, False),
        )

        def signal(history):
            return SignalIntent(quantity=1, stop_distance=1, target_distance=1) if len(history) == 1 else None

        runner = StrategyRunner(make_variant(StrategyDirection.LONG, "UNSAFE"), signal)
        result = CausalBacktestEngine(BacktestConfig(min_completed_trades=1)).run({"NQ": bars}, [runner])
        self.assertEqual(result.trials[0].status, TrialStatus.FAILED_DATA_UNSAFE)
        self.assertIn("entry_bar_unsafe", result.trials[0].failure_reason or "")

    def test_context_partition_and_baselines_are_reported(self):
        bars = make_bars(
            [
                (100, 101, 99, 100),
                (100, 104, 99, 103),
                (103, 104, 102, 103),
            ]
        )

        def signal(history):
            return SignalIntent(quantity=1, stop_distance=5, target_distance=2) if len(history) == 1 else None

        runner = StrategyRunner(make_variant(StrategyDirection.LONG, "CTX"), signal)
        result = CausalBacktestEngine(BacktestConfig(min_completed_trades=1)).run(
            {"NQ": bars},
            [runner],
            context_fn=lambda bar: "OPENING" if bar.timestamp.minute == 30 else "LATER",
        )
        self.assertIn("OPENING", result.context_metrics[runner.runner_id])
        self.assertIn("NQ:BUY_HOLD_LONG", result.baselines)
        self.assertIn("NQ:BUY_HOLD_SHORT", result.baselines)

    def test_repeated_runs_are_reproducible(self):
        bars = make_bars([(100, 101, 99, 100), (100, 104, 99, 103)])

        def signal(history):
            return SignalIntent(quantity=1, stop_distance=5, target_distance=2) if len(history) == 1 else None

        runner = StrategyRunner(make_variant(StrategyDirection.LONG, "REPRO"), signal)
        config = BacktestConfig(min_completed_trades=1, seed=12345)
        engine = CausalBacktestEngine(config)
        first = engine.run({"NQ": bars}, [runner])
        second = engine.run({"NQ": bars}, [runner])

        self.assertEqual(first.seed, second.seed)
        self.assertEqual(first.trials[0].trial_id, second.trials[0].trial_id)
        self.assertEqual(first.trials[0].status, second.trials[0].status)
        self.assertEqual(first.trials[0].net_pnl, second.trials[0].net_pnl)
        self.assertEqual(first.metrics[runner.runner_id], second.metrics[runner.runner_id])


if __name__ == "__main__":
    unittest.main()
