"""Cross-market consolidation and hard-gate robustness decision for BES v1.1."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path("bollinger_ema_sar_v1_1_downloads")
OUT = Path("bollinger_ema_sar_v1_1_crossmarket")
MODES = ["NET3_SIGN", "NET3_2PCT_BB", "NET3_4PCT_BB"]
TARGETS = [0.30, 0.40, 0.50]
HOLDS = [2, 3, 4]
COSTS = [0.03, 0.045, 0.06]


def pf(vals):
    gp = sum(x for x in vals if x > 0)
    gl = abs(sum(x for x in vals if x < 0))
    return gp / gl if gl > 0 else (float("inf") if gp > 0 else 0.0)


def maxdd(vals):
    eq = peak = dd = 0.0
    for x in vals:
        eq += float(x)
        peak = max(peak, eq)
        dd = max(dd, peak - eq)
    return dd


def met(df):
    vals = df["net_r"].astype(float).tolist() if not df.empty else []
    return {
        "trades": int(len(vals)),
        "net_total_r": float(sum(vals)),
        "net_expectancy_r": float(np.mean(vals)) if vals else 0.0,
        "profit_factor": float(pf(vals)),
        "win_rate": float(sum(x > 0 for x in vals) / len(vals)) if vals else 0.0,
        "max_drawdown_r": float(maxdd(vals)),
    }


def bootstrap_p05(vals, reps=1000, block=5, seed=260913):
    vals = np.asarray(vals, dtype=float)
    n = len(vals)
    if n < 10:
        return None
    rng = np.random.default_rng(seed)
    totals = []
    for _ in range(reps):
        out = []
        while len(out) < n:
            s = int(rng.integers(0, n))
            for k in range(block):
                out.append(vals[(s + k) % n])
                if len(out) >= n:
                    break
        totals.append(float(np.sum(out)))
    return float(np.quantile(totals, 0.05))


def main():
    OUT.mkdir(exist_ok=True)
    files = list(ROOT.rglob("*_robustness_trades.csv"))
    frames = []
    for p in files:
        try:
            d = pd.read_csv(p)
            if not d.empty:
                frames.append(d)
        except pd.errors.EmptyDataError:
            pass
    if not frames:
        raise SystemExit("No robustness trade artifacts found")
    df = pd.concat(frames, ignore_index=True)
    # entry_time_et spans DST boundaries, so rows can carry different UTC offsets
    # (-04:00/-05:00). Normalize through UTC, then convert back to New York time
    # before deriving calendar quarters. This changes only transport/parsing, not
    # any preregistered robustness metric or hard gate.
    df["entry_time_et"] = pd.to_datetime(df["entry_time_et"], errors="coerce", utc=True).dt.tz_convert("America/New_York")
    df["quarter"] = df["entry_time_et"].dt.tz_localize(None).dt.to_period("Q").astype(str)
    df.to_csv(OUT / "all_robustness_trades.csv", index=False)

    result = {
        "strategy": "bollinger_ema_sar_v1_1_robustness",
        "window": ["2025-09-25", "2026-09-11"],
        "decision_policy": "hard gates; never choose highest-return mode",
        "modes": {},
        "promoted_modes": [],
        "decision": None,
        "live_money": False,
        "confirmatory_touched": False,
        "sealed_holdout_touched": False,
    }

    for mode in MODES:
        d = df[df["slope_mode"] == mode].copy()
        base = d[(d["target_fraction"] == 0.40) & (d["hold_bars"] == 3) & (np.isclose(d["cost_r"], 0.03))]
        two = d[(d["target_fraction"] == 0.40) & (d["hold_bars"] == 3) & (np.isclose(d["cost_r"], 0.06))]

        cfgs = []
        for t in TARGETS:
            for h in HOLDS:
                for c in COSTS:
                    x = d[(d["target_fraction"] == t) & (d["hold_bars"] == h) & (np.isclose(d["cost_r"], c))]
                    m = met(x)
                    m.update({"target_fraction": t, "hold_bars": h, "cost_r": c})
                    cfgs.append(m)
        positive_perturb = float(sum(x["net_expectancy_r"] > 0 for x in cfgs) / len(cfgs))

        market_metrics = {}
        for sym in sorted(base["symbol"].dropna().unique()):
            market_metrics[str(sym)] = met(base[base["symbol"] == sym])
        positive_markets = sum(m["net_expectancy_r"] > 0 for m in market_metrics.values())
        market_share = float(positive_markets / len(market_metrics)) if market_metrics else 0.0

        quarter_metrics = {}
        for q in sorted(base["quarter"].dropna().unique()):
            quarter_metrics[str(q)] = met(base[base["quarter"] == q])
        positive_quarters = sum(m["net_expectancy_r"] > 0 for m in quarter_metrics.values())
        quarter_share = float(positive_quarters / len(quarter_metrics)) if quarter_metrics else 0.0

        p05 = bootstrap_p05(base.sort_values("entry_time_et")["net_r"].astype(float).tolist())
        bm, tm = met(base), met(two)
        gates = {
            "min_30_trades": bm["trades"] >= 30,
            "base_expectancy_positive": bm["net_expectancy_r"] > 0,
            "two_x_cost_expectancy_positive": tm["net_expectancy_r"] > 0,
            "positive_perturbation_share_ge_60pct": positive_perturb >= 0.60,
            "positive_market_share_ge_50pct": market_share >= 0.50,
            "bootstrap_p05_total_r_positive": p05 is not None and p05 > 0,
        }
        passed = all(gates.values())
        result["modes"][mode] = {
            "base": bm,
            "two_x_cost": tm,
            "positive_perturbation_share": positive_perturb,
            "positive_market_share": market_share,
            "positive_quarter_share": quarter_share,
            "bootstrap_p05_total_r": p05,
            "by_market_base": market_metrics,
            "by_quarter_base": quarter_metrics,
            "hard_gates": gates,
            "passed": passed,
            "configs": cfgs,
        }
        if passed:
            result["promoted_modes"].append(mode)

    result["decision"] = "ROBUST_DISCOVERY_SURVIVOR" if result["promoted_modes"] else "NO_ROBUST_SURVIVOR"
    (OUT / "crossmarket_robustness_summary.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
