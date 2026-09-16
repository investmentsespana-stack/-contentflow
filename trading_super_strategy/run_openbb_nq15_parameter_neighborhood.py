from __future__ import annotations

import json
import math
import os
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path
from statistics import median
from zoneinfo import ZoneInfo

from trading_super_strategy.backtest_engine import BacktestConfig, CausalBacktestEngine, COMPLETED_STATUSES, StrategyRunner
from trading_super_strategy.nq_vol_mean_reversion import (
    R3_FROZEN_PARAMETERS,
    make_r3_runner,
    nq_vol_conditioned_mean_reversion_signal,
)
from trading_super_strategy.openbb_history_adapter import fetch_openbb_futures
from trading_super_strategy.regime_switch_candidates import (
    R2_FROZEN_GRID,
    make_r2_runner,
    regime_switch_signal,
)
from trading_super_strategy.registry_schema import StrategyDirection
from trading_super_strategy.trend_candidates import (
    ma_crossover_signal,
    make_r1_runner,
    past_return_sign_signal,
)

OUT = Path(os.getenv("OUT_DIR", "openbb_nq15_parameter_neighborhood_output"))
START = os.getenv("START_DATE", "2026-07-20")
END = os.getenv("END_DATE", "2026-09-16")
DIRECTION = StrategyDirection.SHORT


def _clone(base: StrategyRunner, signal_fn, tag: str) -> StrategyRunner:
    identity = replace(
        base.variant.identity,
        canonical_id=f"{base.variant.identity.canonical_id}_STRESS_{tag}",
        display_name=f"{base.variant.identity.display_name} stress {tag}",
        version="1.0.0-stress",
    )
    variant = replace(base.variant, identity=identity)
    return StrategyRunner(variant=variant, signal_fn=signal_fn)


def _r2_group(trend_lookback: int):
    base_tuple = (
        trend_lookback,
        20,
        0.60,
        0.25,
        1.50,
    )
    base = make_r2_runner(
        direction=DIRECTION,
        timeframe_minutes=15,
        parameters=base_tuple,
        instruments=("NQ",),
    )
    variants = []
    seen = set()

    def add(params, tag):
        if params in seen:
            return
        seen.add(params)
        t, r, te, re, z = params
        signal = regime_switch_signal(
            DIRECTION,
            trend_lookback=int(t),
            range_lookback=int(r),
            trend_er=float(te),
            range_er=float(re),
            mean_reversion_z=float(z),
        )
        variants.append(_clone(base, signal, tag))

    add(base_tuple, "BASE")
    for value in (round(trend_lookback * 0.8), round(trend_lookback * 1.2)):
        add((value, 20, 0.60, 0.25, 1.50), f"trendlb{value}")
    for value in (16, 24):
        add((trend_lookback, value, 0.60, 0.25, 1.50), f"rangelb{value}")
    for value in (0.55, 0.65):
        add((trend_lookback, 20, value, 0.25, 1.50), f"trender{value:g}")
    for value in (0.20, 0.30):
        add((trend_lookback, 20, 0.60, value, 1.50), f"rangeer{value:g}")
    for value in (1.35, 1.65):
        add((trend_lookback, 20, 0.60, 0.25, value), f"z{value:g}")
    return variants


def _r1_past_return_group():
    base = make_r1_runner(
        family="past_return_sign",
        direction=DIRECTION,
        timeframe_minutes=15,
        parameters=20,
        instruments=("NQ",),
    )
    return [
        _clone(base, past_return_sign_signal(DIRECTION, lookback), f"lb{lookback}")
        for lookback in (16, 20, 24)
    ]


def _r1_ma_group():
    base = make_r1_runner(
        family="ma_crossover",
        direction=DIRECTION,
        timeframe_minutes=15,
        parameters=(10, 30),
        instruments=("NQ",),
    )
    pairs = ((10, 30), (8, 30), (12, 30), (10, 24), (10, 36))
    return [
        _clone(base, ma_crossover_signal(DIRECTION, fast, slow), f"ma{fast}-{slow}")
        for fast, slow in pairs
    ]


def _r3_group():
    base = make_r3_runner(
        direction=DIRECTION,
        timeframe_minutes=15,
        parameters=R3_FROZEN_PARAMETERS,
    )
    base_params = (20, 10, 60, 1.25, 1.75)
    variants = []
    seen = set()

    def add(params, tag):
        if params in seen:
            return
        seen.add(params)
        zlb, sv, lv, ratio, zt = params
        signal = nq_vol_conditioned_mean_reversion_signal(
            DIRECTION,
            z_lookback=int(zlb),
            short_vol_lookback=int(sv),
            long_vol_lookback=int(lv),
            max_vol_ratio=float(ratio),
            z_threshold=float(zt),
        )
        variants.append(_clone(base, signal, tag))

    add(base_params, "BASE")
    for value in (16, 24):
        add((value, 10, 60, 1.25, 1.75), f"zlb{value}")
    for value in (8, 12):
        add((20, value, 60, 1.25, 1.75), f"sv{value}")
    for value in (48, 72):
        add((20, 10, value, 1.25, 1.75), f"lv{value}")
    for value in (1.125, 1.375):
        add((20, 10, 60, value, 1.75), f"vr{value:g}")
    for value in (1.575, 1.925):
        add((20, 10, 60, 1.25, value), f"zt{value:g}")
    return variants


def _groups():
    return {
        "R2_T20_SHORT": _r2_group(20),
        "R2_T60_SHORT": _r2_group(60),
        "R1_PAST_RETURN_20_SHORT": _r1_past_return_group(),
        "R1_MA_10_30_SHORT": _r1_ma_group(),
        "R3_NQ_VOL_MR_SHORT": _r3_group(),
    }


def _max_drawdown(trials):
    completed = [
        t for t in trials
        if t.status in COMPLETED_STATUSES and t.net_pnl is not None
    ]
    completed.sort(key=lambda t: (t.exit_time or t.signal_time, t.trial_id))
    equity = peak = worst = 0.0
    for t in completed:
        equity += float(t.net_pnl or 0.0)
        peak = max(peak, equity)
        worst = max(worst, peak - equity)
    return worst


def _row(result, rid):
    m = result.metrics[rid]
    trials = [t for t in result.trials if t.runner_id == rid]
    return {
        "runner_id": rid,
        "trades": m.completed_trades,
        "win_rate": m.win_rate,
        "net_points": m.net_pnl,
        "expectancy_points": m.expectancy_per_trade,
        "profit_factor": None if math.isinf(m.profit_factor) else m.profit_factor,
        "profit_factor_infinite": math.isinf(m.profit_factor),
        "max_drawdown_points": _max_drawdown(trials),
        "eligible_sample": m.eligible,
    }


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
    groups = _groups()
    all_runners = [runner for runners in groups.values() for runner in runners]

    config = BacktestConfig(
        commission_per_unit_per_side=0.125,
        slippage_per_unit_per_side=0.25,
        min_completed_trades=10,
    )
    result = CausalBacktestEngine(config).run({"NQ": bars}, all_runners)

    output_groups = {}
    for name, runners in groups.items():
        rows = [_row(result, runner.runner_id) for runner in runners]
        nets = [float(row["net_points"]) for row in rows]
        pfs = [
            float(row["profit_factor"])
            for row in rows
            if row["profit_factor"] is not None
        ]
        output_groups[name] = {
            "stress_variant_count": len(rows),
            "positive_count": sum(1 for x in nets if x > 0),
            "positive_fraction": sum(1 for x in nets if x > 0) / len(nets),
            "pf_above_one_count": sum(1 for x in pfs if x > 1.0),
            "median_net_points": median(nets),
            "worst_net_points": min(nets),
            "best_net_points": max(nets),
            "rows": rows,
        }

    payload = {
        "study": "openbb_nq15_parameter_neighborhood_v1",
        "purpose": "one-at-a-time parameter perturbation for fragility testing; never select the best perturbation",
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
        "cost_stress": "1 NQ tick (0.25 point) slippage/side + 0.125 point commission/side",
        "total_stress_variants": len(all_runners),
        "groups": output_groups,
        "governance": [
            "Perturbations are robustness stress variants, not candidate search variants.",
            "No best perturbation may replace the preregistered baseline.",
            "Positive neighborhood behavior does not constitute OOS or robustness certification.",
            "All attempts are retained in the evidence artifact; none are hidden.",
        ],
    }

    OUT.mkdir(parents=True, exist_ok=True)
    path = OUT / "summary.json"
    path.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(payload, indent=2, sort_keys=True))
    print(f"RESULT_PATH={path}")


if __name__ == "__main__":
    main()
