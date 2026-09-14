"""Discovery robustness checks for Bollinger/EMA/SAR V2.

Uses only 2025-09-25..2026-09-11. It does NOT touch confirmatory or sealed holdout
windows. The 0.05 slope threshold remains the primary preregistered rule; nearby
thresholds are perturbation checks only and must not be selected by best return.
"""
from __future__ import annotations

import json
import math
from collections import Counter, defaultdict
from pathlib import Path

import numpy as np
import pandas as pd

import bollinger_ema_sar_v1_backtest as v1
import bollinger_ema_sar_v2_slope_backtest as v2

OUT = Path("bollinger_ema_sar_v2_robustness_output")
THRESHOLDS = [0.025, 0.05, 0.075, 0.10]
COSTS = {"baseline": 0.03, "cost_1_5x": 0.045, "cost_2x": 0.06}
MC_REPS = 2000
MC_BLOCK = 5
MC_SEED = 260913


def pf(vals):
    gp = sum(x for x in vals if x > 0)
    gl = abs(sum(x for x in vals if x < 0))
    return gp / gl if gl > 0 else (float("inf") if gp > 0 else 0.0)


def max_dd(vals):
    eq = peak = dd = 0.0
    for x in vals:
        eq += float(x)
        peak = max(peak, eq)
        dd = max(dd, peak - eq)
    return float(dd)


def metrics_from_vals(vals):
    vals = [float(x) for x in vals]
    if not vals:
        return {"trades": 0, "total_r": 0.0, "expectancy_r": 0.0, "profit_factor": 0.0, "win_rate": 0.0, "max_drawdown_r": 0.0}
    return {
        "trades": len(vals),
        "total_r": float(sum(vals)),
        "expectancy_r": float(np.mean(vals)),
        "profit_factor": float(pf(vals)),
        "win_rate": float(sum(x > 0 for x in vals) / len(vals)),
        "max_drawdown_r": max_dd(vals),
    }


def block_bootstrap(vals, reps=MC_REPS, block=MC_BLOCK, seed=MC_SEED):
    vals = np.asarray(vals, dtype=float)
    n = len(vals)
    if n == 0:
        return {"replications": reps, "block_length": block, "p05_total_r": 0.0, "median_total_r": 0.0, "p95_total_r": 0.0, "prob_total_r_le_0": 1.0, "p95_max_drawdown_r": 0.0}
    rng = np.random.default_rng(seed)
    totals, dds = [], []
    max_start = max(1, n - min(block, n) + 1)
    for _ in range(reps):
        sample = []
        while len(sample) < n:
            start = int(rng.integers(0, max_start))
            sample.extend(vals[start:start + min(block, n)].tolist())
        sample = sample[:n]
        totals.append(float(sum(sample)))
        dds.append(max_dd(sample))
    a = np.asarray(totals)
    d = np.asarray(dds)
    return {
        "replications": reps,
        "block_length": block,
        "p05_total_r": float(np.quantile(a, 0.05)),
        "median_total_r": float(np.quantile(a, 0.50)),
        "p95_total_r": float(np.quantile(a, 0.95)),
        "prob_total_r_le_0": float(np.mean(a <= 0.0)),
        "p95_max_drawdown_r": float(np.quantile(d, 0.95)),
    }


def run_symbol(symbol: str, threshold: float):
    g = v2.enrich_v2(v1.load_market(symbol))
    old = v2.SLOPE_THRESHOLD
    v2.SLOPE_THRESHOLD = threshold
    try:
        long_parts, short_parts, long_mask, short_mask, pats = v2.signal_masks_v2(g)
    finally:
        v2.SLOPE_THRESHOLD = old

    trades = []
    i = 205
    while i < len(g) - 1:
        long_ok = bool(long_mask.iloc[i])
        short_ok = bool(short_mask.iloc[i])
        if long_ok == short_ok:
            i += 1
            continue
        direction = 1 if long_ok else -1
        result = v1.run_trade(g, i, direction)
        if result is None:
            i += 1
            continue
        row = g.iloc[i]
        rec = {
            "threshold": float(threshold),
            "symbol": symbol,
            "direction": "LONG" if direction == 1 else "SHORT",
            "signal_time_et": str(row["local_time"]),
            "entry_time_et": str(g.iloc[result["entry_i"]]["local_time"]),
            "exit_time_et": str(g.iloc[result["exit_i"]]["local_time"]),
            "session": str(row["session"]),
            "pattern": v1.pattern_name(i, direction, pats),
            "slope_norm": float(row["ema20_slope_norm"]),
            "gross_r": float(result["gross_r"]),
            "baseline_net_r": float(result["gross_r"] - COSTS["baseline"]),
            "exit_reason": str(result["exit_reason"]),
        }
        trades.append(rec)
        i = int(result["exit_i"]) + 1
    return trades, {
        "LONG": v1.cumulative_funnel(long_parts),
        "SHORT": v1.cumulative_funnel(short_parts),
    }


def summarize(df: pd.DataFrame):
    if df.empty:
        return {"overall": metrics_from_vals([])}
    out = {
        "overall": metrics_from_vals(df["baseline_net_r"].tolist()),
        "cost_stress": {},
        "by_direction": {},
        "by_symbol": {},
        "by_pattern": {},
        "by_session": {},
        "by_quarter": {},
        "temporal_halves": {},
        "exit_reasons": dict(Counter(df["exit_reason"])),
    }
    for label, c in COSTS.items():
        out["cost_stress"][label] = metrics_from_vals((df["gross_r"] - c).tolist())
    for d in sorted(df["direction"].unique()):
        sub = df[df["direction"] == d]
        out["by_direction"][d] = metrics_from_vals(sub["baseline_net_r"].tolist())
    for s in sorted(df["symbol"].unique()):
        sub = df[df["symbol"] == s]
        out["by_symbol"][s] = metrics_from_vals(sub["baseline_net_r"].tolist())
    for p in sorted(df["pattern"].unique()):
        sub = df[df["pattern"] == p]
        out["by_pattern"][p] = metrics_from_vals(sub["baseline_net_r"].tolist())
    for sess in sorted(df["session"].unique()):
        sub = df[df["session"] == sess]
        out["by_session"][sess] = metrics_from_vals(sub["baseline_net_r"].tolist())

    ts = pd.to_datetime(df["signal_time_et"], utc=True)
    q = ts.dt.to_period("Q").astype(str)
    for qq in sorted(q.unique()):
        out["by_quarter"][qq] = metrics_from_vals(df.loc[q == qq, "baseline_net_r"].tolist())

    midpoint = pd.Timestamp("2026-03-20T00:00:00Z")
    out["temporal_halves"]["early"] = metrics_from_vals(df.loc[ts < midpoint, "baseline_net_r"].tolist())
    out["temporal_halves"]["late"] = metrics_from_vals(df.loc[ts >= midpoint, "baseline_net_r"].tolist())

    chron = df.assign(_ts=ts).sort_values("_ts")["baseline_net_r"].tolist()
    out["moving_block_monte_carlo"] = block_bootstrap(chron)
    return out


def main():
    OUT.mkdir(exist_ok=True)
    rows = []
    funnels = defaultdict(dict)
    for threshold in THRESHOLDS:
        for symbol in sorted(v1.SYMBOLS):
            trades, funnel = run_symbol(symbol, threshold)
            rows.extend(trades)
            funnels[str(threshold)][symbol] = funnel

    all_df = pd.DataFrame(rows)
    all_df.to_csv(OUT / "all_threshold_trades.csv", index=False)

    report = {
        "strategy": "bollinger_ema_sar_v2_robustness",
        "window": [str(v1.START), str(v1.END)],
        "primary_threshold": 0.05,
        "thresholds": THRESHOLDS,
        "selection_rule": "Do not choose the best threshold from this discovery window; use perturbations only to judge stability.",
        "results": {},
        "filter_funnels": funnels,
        "decision": "DISCOVERY_ROBUSTNESS_ONLY_NO_LIVE",
    }
    for threshold in THRESHOLDS:
        sub = all_df[np.isclose(all_df["threshold"], threshold)] if not all_df.empty else all_df
        report["results"][str(threshold)] = summarize(sub)

    primary = report["results"]["0.05"]["overall"]
    report["primary_readout"] = {
        "trades": primary["trades"],
        "expectancy_r": primary["expectancy_r"],
        "profit_factor": primary["profit_factor"],
        "stable_positive_after_2x_cost": report["results"]["0.05"]["cost_stress"]["cost_2x"]["expectancy_r"] > 0,
        "both_halves_positive": (
            report["results"]["0.05"]["temporal_halves"]["early"]["expectancy_r"] > 0 and
            report["results"]["0.05"]["temporal_halves"]["late"]["expectancy_r"] > 0
        ),
        "mc_p05_positive": report["results"]["0.05"]["moving_block_monte_carlo"]["p05_total_r"] > 0,
    }

    (OUT / "robustness_summary.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
