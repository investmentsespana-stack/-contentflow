from __future__ import annotations

import json
import math
import os
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

from trading_super_strategy.backtest_engine import BacktestConfig, CausalBacktestEngine, COMPLETED_STATUSES
from trading_super_strategy.nq_vol_mean_reversion import R3_FROZEN_PARAMETERS, make_r3_runner
from trading_super_strategy.openbb_history_adapter import fetch_openbb_futures
from trading_super_strategy.regime_switch_candidates import R2_FROZEN_GRID, make_r2_runner
from trading_super_strategy.registry_schema import StrategyDirection
from trading_super_strategy.robustness_engine import (
    MonteCarloConfig,
    MonteCarloRobustnessEngine,
    walk_forward_stability,
)
from trading_super_strategy.trend_candidates import make_r1_runner

OUT = Path(os.getenv("STRESS_OUT", "openbb_nq15_survivor_stress_output"))
START = os.getenv("START_DATE", "2026-07-20")
END = os.getenv("END_DATE", "2026-09-16")


def _survivors():
    short = StrategyDirection.SHORT
    return [
        make_r2_runner(
            direction=short,
            timeframe_minutes=15,
            parameters=R2_FROZEN_GRID["er_switch"][0],
            instruments=("NQ",),
        ),
        make_r2_runner(
            direction=short,
            timeframe_minutes=15,
            parameters=R2_FROZEN_GRID["er_switch"][1],
            instruments=("NQ",),
        ),
        make_r1_runner(
            family="past_return_sign",
            direction=short,
            timeframe_minutes=15,
            parameters=20,
            instruments=("NQ",),
        ),
        make_r1_runner(
            family="ma_crossover",
            direction=short,
            timeframe_minutes=15,
            parameters=(10, 30),
            instruments=("NQ",),
        ),
        make_r3_runner(
            direction=short,
            timeframe_minutes=15,
            parameters=R3_FROZEN_PARAMETERS,
        ),
    ]


def _metrics(result, runner_id: str):
    m = result.metrics[runner_id]
    trials = [
        t for t in result.trials
        if t.runner_id == runner_id and t.status in COMPLETED_STATUSES and t.net_pnl is not None
    ]
    equity = 0.0
    peak = 0.0
    max_dd = 0.0
    for t in sorted(trials, key=lambda x: (x.exit_time or x.signal_time, x.trial_id)):
        equity += float(t.net_pnl or 0.0)
        peak = max(peak, equity)
        max_dd = max(max_dd, peak - equity)
    return {
        "trades": m.completed_trades,
        "wins": m.wins,
        "losses": m.losses,
        "win_rate": m.win_rate,
        "net_points": m.net_pnl,
        "expectancy_points": m.expectancy_per_trade,
        "profit_factor": None if math.isinf(m.profit_factor) else m.profit_factor,
        "profit_factor_infinite": math.isinf(m.profit_factor),
        "max_drawdown_points": max_dd,
    }


def _completed_returns_r(result, runner_id: str):
    trials = [
        t for t in result.trials
        if t.runner_id == runner_id and t.status in COMPLETED_STATUSES and t.net_pnl is not None
    ]
    trials.sort(key=lambda x: (x.exit_time or x.signal_time, x.trial_id))
    values = []
    for t in trials:
        risk_points = float(t.stop_distance) * float(t.quantity)
        if risk_points > 0:
            values.append(float(t.net_pnl) / risk_points)
    return values


def _segment_bars(bars, parts=4):
    n = len(bars)
    segments = []
    for i in range(parts):
        start = (n * i) // parts
        end = (n * (i + 1)) // parts
        chunk = bars[start:end]
        if chunk:
            segments.append(chunk)
    return segments


def main():
    bars, stats = fetch_openbb_futures(
        symbol="NQ",
        interval="15m",
        start_date=START,
        end_date=END,
        provider="yfinance",
        transport="python",
        naive_timezone=ZoneInfo("America/New_York"),
    )
    runners = _survivors()

    cost_scenarios = {
        "1tick": BacktestConfig(
            commission_per_unit_per_side=0.125,
            slippage_per_unit_per_side=0.25,
            min_completed_trades=10,
        ),
        "2tick": BacktestConfig(
            commission_per_unit_per_side=0.125,
            slippage_per_unit_per_side=0.50,
            min_completed_trades=10,
        ),
        "4tick": BacktestConfig(
            commission_per_unit_per_side=0.125,
            slippage_per_unit_per_side=1.00,
            min_completed_trades=10,
        ),
    }

    full_results = {
        label: CausalBacktestEngine(config).run({"NQ": bars}, runners)
        for label, config in cost_scenarios.items()
    }

    segments = _segment_bars(bars, 4)
    segment_results = []
    base_config = cost_scenarios["1tick"]
    for index, chunk in enumerate(segments, start=1):
        result = CausalBacktestEngine(base_config).run({"NQ": chunk}, runners)
        segment_results.append(
            {
                "segment": index,
                "first_timestamp": chunk[0].timestamp.isoformat(),
                "last_timestamp": chunk[-1].timestamp.isoformat(),
                "bars": len(chunk),
                "metrics": {r.runner_id: _metrics(result, r.runner_id) for r in runners},
            }
        )

    mc_engine = MonteCarloRobustnessEngine()
    candidates = {}
    base_result = full_results["1tick"]
    for runner in runners:
        rid = runner.runner_id
        returns_r = _completed_returns_r(base_result, rid)
        mc = mc_engine.run(
            returns_r,
            MonteCarloConfig(
                iterations=5000,
                seed=17,
                omit_trade_probability=0.05,
                extra_cost_r=0.05,
                slippage_r_std=0.05,
                ruin_drawdown_r=10.0,
            ),
        )
        window_size = max(10, len(returns_r) // 4)
        wf = walk_forward_stability(returns_r, window_size)
        full = {label: _metrics(result, rid) for label, result in full_results.items()}
        seg = [item["metrics"][rid] for item in segment_results]
        candidates[rid] = {
            "full_cost_stress": full,
            "positive_segments_1tick": sum(1 for x in seg if x["net_points"] > 0),
            "segments_1tick": seg,
            "returns_r_count": len(returns_r),
            "walk_forward_trade_blocks": {
                "window_size_trades": window_size,
                "windows": wf.windows,
                "positive_window_rate": wf.positive_window_rate,
                "median_window_r": wf.median_window_r,
                "worst_window_r": wf.worst_window_r,
                "stability_score": wf.stability_score,
            },
            "monte_carlo_5000": {
                "profitable_probability": mc.profitable_probability,
                "ruin_probability": mc.ruin_probability,
                "median_total_r": mc.median_total_r,
                "p05_total_r": mc.p05_total_r,
                "median_max_drawdown_r": mc.median_max_drawdown_r,
                "p95_max_drawdown_r": mc.p95_max_drawdown_r,
                "median_win_rate": mc.median_win_rate,
                "stress": {
                    "omit_trade_probability": 0.05,
                    "extra_cost_r": 0.05,
                    "slippage_r_std": 0.05,
                    "ruin_drawdown_r": 10.0,
                },
            },
            "screen_flags": {
                "positive_at_1tick": full["1tick"]["net_points"] > 0,
                "positive_at_2tick": full["2tick"]["net_points"] > 0,
                "positive_at_4tick": full["4tick"]["net_points"] > 0,
                "positive_in_at_least_3_of_4_segments": sum(1 for x in seg if x["net_points"] > 0) >= 3,
                "mc_p05_positive": mc.p05_total_r > 0,
                "mc_ruin_below_5pct": mc.ruin_probability < 0.05,
            },
        }

    payload = {
        "study": "openbb_nq15_survivor_stress_v1",
        "purpose": "falsification stress on discovery survivors; not robustness certification",
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "source": {
            "provider": stats.provider,
            "symbol": stats.symbol,
            "interval": stats.interval,
            "requested_start": START,
            "requested_end": END,
            "bars": stats.output_bars,
            "first_timestamp": stats.first_timestamp.isoformat(),
            "last_timestamp": stats.last_timestamp.isoformat(),
        },
        "candidate_count": len(runners),
        "cost_scenarios": {
            "1tick": "0.25 point slippage/side + 0.125 point commission/side",
            "2tick": "0.50 point slippage/side + 0.125 point commission/side",
            "4tick": "1.00 point slippage/side + 0.125 point commission/side",
        },
        "candidates": candidates,
        "segment_metadata": [
            {k: v for k, v in item.items() if k != "metrics"}
            for item in segment_results
        ],
        "limitations": [
            "Same recent Yahoo discovery window as first screen; not untouched OOS.",
            "Continuous futures may contain roll effects.",
            "DSR/PBO are intentionally not used as promotion evidence on this short reused window.",
            "Multi-year independent data remains mandatory before paper/shadow promotion.",
        ],
    }

    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "summary.json"
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(payload, indent=2, sort_keys=True))
    print(f"RESULT_PATH={path}")


if __name__ == "__main__":
    main()
