"""Consolidate V4 discovery robustness evidence and apply preregistered hard gates."""
from __future__ import annotations

import json
from datetime import date
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path("bollinger_ema_sar_v4_robustness_downloads")
OUT = Path("bollinger_ema_sar_v4_robustness_crossmarket")
START = date(2025, 9, 25)
END = date(2026, 9, 11)
BASE_EXIT = 3
BASE_COST = 0.03
COSTS = (0.03, 0.045, 0.06)
MC_REPS = 5000
MC_BLOCK = 10
MC_SEED = 260914


def profit_factor(vals) -> float:
    gp = float(sum(x for x in vals if x > 0))
    gl = abs(float(sum(x for x in vals if x < 0)))
    return gp / gl if gl > 0 else (float("inf") if gp > 0 else 0.0)


def max_dd(vals) -> float:
    eq = peak = dd = 0.0
    for x in vals:
        eq += float(x)
        peak = max(peak, eq)
        dd = max(dd, peak - eq)
    return float(dd)


def metrics(df: pd.DataFrame, cost_r: float = BASE_COST) -> dict:
    if df.empty:
        return {"trades": 0, "net_total_r": 0.0, "net_expectancy_r": 0.0, "net_profit_factor": 0.0,
                "net_win_rate": 0.0, "net_max_drawdown_r": 0.0, "mean_bars_held": 0.0}
    vals = (df["gross_r"].astype(float) - float(cost_r)).tolist()
    return {
        "trades": int(len(df)),
        "net_total_r": float(sum(vals)),
        "net_expectancy_r": float(np.mean(vals)),
        "net_profit_factor": float(profit_factor(vals)),
        "net_win_rate": float(np.mean(np.array(vals) > 0)),
        "net_max_drawdown_r": max_dd(vals),
        "mean_bars_held": float(df["bars_held"].astype(float).mean()),
    }


def moving_block_bootstrap(vals: np.ndarray) -> dict:
    n = len(vals)
    if n < 30:
        return {"eligible": False, "n": n}
    block = min(MC_BLOCK, n)
    rng = np.random.default_rng(MC_SEED)
    starts_max = max(1, n - block + 1)
    totals = np.empty(MC_REPS, dtype=float)
    for r in range(MC_REPS):
        sample = []
        while len(sample) < n:
            s = int(rng.integers(0, starts_max))
            sample.extend(vals[s:s + block].tolist())
        totals[r] = float(np.sum(sample[:n]))
    return {
        "eligible": True,
        "replications": MC_REPS,
        "block_length_trades": block,
        "p05_total_r": float(np.quantile(totals, 0.05)),
        "median_total_r": float(np.quantile(totals, 0.50)),
        "p95_total_r": float(np.quantile(totals, 0.95)),
        "prob_total_r_le_zero": float(np.mean(totals <= 0.0)),
    }


def group_metrics(df: pd.DataFrame, column: str) -> dict:
    out = {}
    for value, g in df.groupby(column, dropna=False):
        out[str(value)] = metrics(g)
    return out


def main():
    OUT.mkdir(exist_ok=True)
    files = list(ROOT.rglob("*_robustness_trades.csv"))
    frames = [pd.read_csv(p) for p in files if p.stat().st_size > 0]
    if not frames:
        raise SystemExit("No V4 robustness trade files found")
    df = pd.concat(frames, ignore_index=True)
    df["entry_ts"] = pd.to_datetime(df["entry_time_et"], utc=True)
    df = df.sort_values(["exit_count", "entry_ts", "symbol"]).reset_index(drop=True)
    df.to_csv(OUT / "all_exit_neighbor_trades.csv", index=False)

    baseline = df[df["exit_count"].astype(int) == BASE_EXIT].copy().sort_values(["entry_ts", "symbol"])
    if baseline.empty:
        raise SystemExit("Baseline exit_count=3 is empty")

    cost_stress = {str(c): metrics(baseline, c) for c in COSTS}
    exit_neighbors = {str(n): metrics(df[df["exit_count"].astype(int) == n], BASE_COST) for n in (2, 3, 4)}

    midpoint = START + (END - START) // 2
    baseline["entry_date"] = baseline["entry_ts"].dt.date
    early = baseline[baseline["entry_date"] <= midpoint]
    late = baseline[baseline["entry_date"] > midpoint]
    halves = {"first_half": metrics(early), "second_half": metrics(late), "midpoint_date": str(midpoint)}

    baseline["quarter"] = baseline["entry_ts"].dt.tz_localize(None).dt.to_period("Q").astype(str)
    quarters = group_metrics(baseline, "quarter")
    q_nonempty = [m for m in quarters.values() if m["trades"] > 0]
    positive_quarter_fraction = float(np.mean([m["net_expectancy_r"] > 0 for m in q_nonempty])) if q_nonempty else 0.0

    by_market = group_metrics(baseline, "symbol")
    by_direction = group_metrics(baseline, "direction")
    baseline["market_direction"] = baseline["symbol"].astype(str) + "|" + baseline["direction"].astype(str)
    by_market_direction = group_metrics(baseline, "market_direction")
    by_pattern = group_metrics(baseline, "pattern")
    by_session = group_metrics(baseline, "session")
    by_phase = group_metrics(baseline, "ema9_20_phase") if "ema9_20_phase" in baseline.columns else {}

    market_nonempty = [m for m in by_market.values() if m["trades"] > 0]
    positive_market_fraction = float(np.mean([m["net_expectancy_r"] > 0 for m in market_nonempty])) if market_nonempty else 0.0

    baseline_net = (baseline["gross_r"].astype(float) - BASE_COST).to_numpy(dtype=float)
    mc = moving_block_bootstrap(baseline_net)

    base_m = cost_stress[str(BASE_COST)]
    c15 = cost_stress[str(0.045)]
    c2 = cost_stress[str(0.06)]
    gates = {
        "minimum_300_trades": base_m["trades"] >= 300,
        "baseline_expectancy_positive": base_m["net_expectancy_r"] > 0,
        "baseline_pf_gt_1_05": base_m["net_profit_factor"] > 1.05,
        "cost_1_5x_expectancy_positive": c15["net_expectancy_r"] > 0,
        "cost_2x_expectancy_nonnegative": c2["net_expectancy_r"] >= 0,
        "both_time_halves_positive": halves["first_half"]["net_expectancy_r"] > 0 and halves["second_half"]["net_expectancy_r"] > 0,
        "positive_quarter_fraction_ge_0_60": positive_quarter_fraction >= 0.60,
        "positive_market_fraction_ge_0_75": positive_market_fraction >= 0.75,
        "exit_neighbor_2_nonnegative": exit_neighbors["2"]["net_expectancy_r"] >= 0,
        "exit_neighbor_4_nonnegative": exit_neighbors["4"]["net_expectancy_r"] >= 0,
        "moving_block_mc_p05_positive": bool(mc.get("eligible")) and float(mc.get("p05_total_r", -1.0)) > 0,
    }
    passed = all(gates.values())

    result = {
        "strategy": "bollinger_ema_sar_v4_robustness",
        "status": "PASS_DISCOVERY_ROBUSTNESS" if passed else "FAIL_DISCOVERY_ROBUSTNESS",
        "live_money": False,
        "data_governance": {
            "discovery_only": [str(START), str(END)],
            "confirmatory_2022_2025_touched": False,
            "consumed_2018_2019_used": False,
            "sealed_holdout_2020_2022_touched": False,
        },
        "baseline_exit_count": BASE_EXIT,
        "cost_stress": cost_stress,
        "exit_neighbors": exit_neighbors,
        "fixed_time_halves": halves,
        "calendar_quarters": quarters,
        "positive_quarter_fraction": positive_quarter_fraction,
        "by_market": by_market,
        "positive_market_fraction": positive_market_fraction,
        "by_direction": by_direction,
        "by_market_direction": by_market_direction,
        "by_pattern": by_pattern,
        "by_session": by_session,
        "by_ema9_20_phase_diagnostic_only": by_phase,
        "moving_block_monte_carlo": mc,
        "hard_gates": gates,
        "decision": "FREEZE_V4_FOR_CONFIRMATORY" if passed else "DO_NOT_OPEN_CONFIRMATORY",
        "note": "EMA9/20 cross during trade is post-entry diagnostic evidence only; it was not used as an entry selector.",
    }
    (OUT / "v4_robustness_summary.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
