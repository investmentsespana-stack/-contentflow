"""Independent pre-holdout validation for the three frozen LONG portfolios.

The portfolios and weights are read from the artifact frozen BEFORE portfolio
robustness in run 34781565340. No weights, components, thresholds, or B/C rules are
changed. This script evaluates only LONG_EQUAL_ALL, LONG_MARKET_BALANCED, and
LONG_FAMILY_BALANCED on the previously unused 2018-01-02..2019-12-31 window.
The sealed final holdout 2020-01-02..2022-08-31 is never requested or read.
Research only; LIVE MONEY remains false.
"""
from __future__ import annotations

import json
import math
import random
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd

import real_strategy_discovery as base
from phase2_historical_search import _trade_outcome_arrays
from phase3_multiyear_validation import BASELINE_COST_R
from phase3_risk_gate_v2 import (
    capital_max_drawdown,
    cscv_pbo,
    deflated_sharpe_probability,
    percentile,
    sample_moving_blocks,
)
from robustness_engine import max_drawdown_r

SRC = Path("long_independent_inputs/directional_portfolios.json")
CACHE_DIR = Path("long_independent_cache")
OUT = Path("long_independent_output")
TARGET_IDS = {
    "LONG_EQUAL_ALL",
    "LONG_MARKET_BALANCED",
    "LONG_FAMILY_BALANCED",
}
MC_ITER = 2000
BLOCKS = (5, 20)
RISK_FRACTION = 0.0025
DD_BUDGET = 0.10
PBO_MAX = 0.50
INDEPENDENT_START = "2018-01-02"
INDEPENDENT_END = "2019-12-31"


def direction_value(value):
    return 1 if str(value).upper() == "LONG" else -1


def build_features(path: Path):
    df = pd.read_parquet(path)
    idx = pd.DatetimeIndex(df.index)
    if idx.tz is None:
        idx = idx.tz_localize("UTC")
    work = df.copy()
    work["local_time"] = idx.tz_convert(base.TZ)
    work = work.sort_values("local_time")
    work = work[~work.index.duplicated(keep="first")].copy()
    g = base.enrich_symbol(work).reset_index(drop=True)
    close = g["close"].astype(float)
    atr = g["atr14"].astype(float)
    g["slope_fast_atr"] = (close - close.shift(5)) / atr.replace(0.0, np.nan)
    g["slope_medium_atr"] = (close - close.shift(20)) / atr.replace(0.0, np.nan)
    g["slope_slow_atr"] = (close - close.shift(60)) / atr.replace(0.0, np.nan)
    path20 = close.diff().abs().rolling(20).sum()
    g["trend_efficiency20"] = (close - close.shift(20)).abs() / path20.replace(0.0, np.nan)
    g["trend_efficiency_threshold"] = g["trend_efficiency20"].rolling(120, min_periods=60).median().shift(1)
    target = g["atr60_med"].shift(1)
    g["risk_scale"] = (target / atr.replace(0.0, np.nan)).clip(lower=0.25, upper=1.0)
    return g


def replay_component(g, component):
    local_times = g["local_time"].tolist()
    session_arr = np.array([base.session_label(ts) for ts in local_times], dtype=object)
    bucket_arr = np.array([base.open_bucket(ts) for ts in local_times], dtype=object)
    vol_regime = g["vol_regime"].astype(str).to_numpy()
    trend_regime = g["trend_regime"].astype(str).to_numpy()
    structure_regime = g["structure_regime"].astype(str).to_numpy()
    signal_arrays = {name: g[f"sig_{name}"].fillna(0).astype(int).to_numpy() for name in base.STRATEGIES}
    open_ = g["open"].astype(float).to_numpy()
    high = g["high"].astype(float).to_numpy()
    low = g["low"].astype(float).to_numpy()
    close = g["close"].astype(float).to_numpy()
    atr = g["atr14"].astype(float).to_numpy()
    sf = g["slope_fast_atr"].to_numpy()
    sm = g["slope_medium_atr"].to_numpy()
    ss = g["slope_slow_atr"].to_numpy()
    eff = g["trend_efficiency20"].to_numpy()
    eff_thr = g["trend_efficiency_threshold"].to_numpy()
    scale_arr = g["risk_scale"].to_numpy()

    c = component["context"]
    d = direction_value("LONG")
    rr = float(component["rr"])
    mask = (
        (session_arr == c["session"])
        & (bucket_arr == c["minutes_from_open_bucket"])
        & (vol_regime == c["volatility_regime"])
        & (trend_regime == c["trend_regime"])
        & (structure_regime == c["structure_regime"])
    )
    for member in component["members"]:
        mask &= signal_arrays[member] == d

    daily_gross = defaultdict(float)
    daily_cost_units = defaultdict(float)
    trades = 0
    for pos in np.flatnonzero(mask):
        if pos + 1 >= len(g) or not math.isfinite(float(atr[pos])) or atr[pos] <= 0:
            continue
        gross = _trade_outcome_arrays(open_, high, low, close, atr, int(pos), d, rr)
        if gross is None:
            continue
        votes = sum(1 for v in (sf[pos], sm[pos], ss[pos]) if math.isfinite(float(v)) and d * float(v) > 0)
        quality = (
            math.isfinite(float(eff[pos]))
            and math.isfinite(float(eff_thr[pos]))
            and float(eff[pos]) >= float(eff_thr[pos])
        )
        if votes < 2 or not quality:
            continue
        scale = float(scale_arr[pos]) if math.isfinite(float(scale_arr[pos])) else 1.0
        scale = min(1.0, max(0.25, scale))
        day = str(local_times[pos + 1].date())
        daily_gross[day] += float(gross) * scale
        daily_cost_units[day] += scale
        trades += 1
    return {"gross": dict(daily_gross), "cost_units": dict(daily_cost_units), "trades": trades}


def pf(vals):
    gp = sum(x for x in vals if x > 0)
    gl = abs(sum(x for x in vals if x < 0))
    return gp / gl if gl > 0 else (float("inf") if gp > 0 else 0.0)


def metrics(vals):
    arr = [float(x) for x in vals]
    mu = float(np.mean(arr)) if arr else 0.0
    vol = float(np.std(arr)) if arr else 0.0
    return {
        "days": len(arr),
        "active_days": sum(abs(x) > 1e-12 for x in arr),
        "total_r": float(sum(arr)),
        "mean_daily_r": mu,
        "profit_factor": pf(arr),
        "max_drawdown_r": float(max_drawdown_r(arr)),
        "positive_day_rate": (sum(x > 0 for x in arr) / len(arr)) if arr else 0.0,
        "sharpe_annualized": (math.sqrt(252.0) * mu / vol) if vol > 0 else 0.0,
    }


def mc(vals, block, seed):
    rng = random.Random(seed + block * 101)
    totals, dds, capital = [], [], []
    breach = 0
    for _ in range(MC_ITER):
        path = sample_moving_blocks(vals, block, rng)
        totals.append(sum(path))
        dds.append(max_drawdown_r(path))
        dd = capital_max_drawdown(path, RISK_FRACTION)
        capital.append(dd)
        breach += int(dd >= DD_BUDGET)
    return {
        "iterations": MC_ITER,
        "block_length": block,
        "p05_total_r": percentile(totals, 0.05),
        "median_total_r": percentile(totals, 0.50),
        "p95_max_drawdown_r": percentile(dds, 0.95),
        "p99_max_drawdown_r": percentile(dds, 0.99),
        "capital_drawdown_breach_probability": breach / MC_ITER,
        "p95_capital_max_drawdown": percentile(capital, 0.95),
        "p99_capital_max_drawdown": percentile(capital, 0.99),
    }


def main():
    frozen = json.loads(SRC.read_text(encoding="utf-8"))
    portfolios = [p for p in frozen if p.get("portfolio_id") in TARGET_IDS]
    if {p["portfolio_id"] for p in portfolios} != TARGET_IDS:
        raise SystemExit("Frozen artifact is missing one or more target LONG portfolios")
    if any(p.get("direction") != "LONG" for p in portfolios):
        raise SystemExit("Independent validation target must be LONG only")

    by_symbol = {}
    for p in portfolios:
        for comp in p["components"]:
            by_symbol.setdefault(comp["symbol"], {})[comp["candidate_key"]] = comp

    feature_cache = {}
    replay = {}
    for symbol, comps in by_symbol.items():
        path = CACHE_DIR / f"{symbol}.parquet"
        if not path.exists():
            raise SystemExit(f"Missing independent checkpoint: {path}")
        g = build_features(path)
        feature_cache[symbol] = g
        for key, comp in comps.items():
            replay[key] = replay_component(g, comp)

    results = []
    for idx, p in enumerate(sorted(portfolios, key=lambda x: x["portfolio_id"]), start=1):
        all_dates = sorted({d for comp in p["components"] for d in replay[comp["candidate_key"]]["gross"]} |
                           {d for comp in p["components"] for d in replay[comp["candidate_key"]]["cost_units"]})
        gross = {d: 0.0 for d in all_dates}
        units = {d: 0.0 for d in all_dates}
        for comp in p["components"]:
            w = float(comp["weight"])
            x = replay[comp["candidate_key"]]
            for d, v in x["gross"].items():
                gross[d] += w * float(v)
            for d, v in x["cost_units"].items():
                units[d] += w * float(v)

        base = [gross[d] - BASELINE_COST_R * units[d] for d in all_dates]
        s15 = [gross[d] - 1.5 * BASELINE_COST_R * units[d] for d in all_dates]
        s20 = [gross[d] - 2.0 * BASELINE_COST_R * units[d] for d in all_dates]
        year_vals = defaultdict(list)
        quarter_vals = defaultdict(float)
        for d, v in zip(all_dates, base):
            year_vals[d[:4]].append(v)
            q = (int(d[5:7]) - 1) // 3 + 1
            quarter_vals[f"{d[:4]}Q{q}"] += float(v)
        folds = []
        for y in sorted(year_vals):
            m = metrics(year_vals[y])
            m["year"] = int(y)
            folds.append(m)
        positive_fold_rate = sum(f["total_r"] > 0 for f in folds) / len(folds) if folds else 0.0
        mcs = [mc(s20, block, 12000 + idx) for block in BLOCKS]
        worst_p05 = min(x["p05_total_r"] for x in mcs)
        worst_ruin = max(x["capital_drawdown_breach_probability"] for x in mcs)
        bm = metrics(base)
        m20 = metrics(s20)
        dsr3 = deflated_sharpe_probability(base, 3)
        dsr8_diag = deflated_sharpe_probability(base, 8)
        fail = []
        if bm["active_days"] < 60:
            fail.append("insufficient_active_days")
        if bm["total_r"] <= 0:
            fail.append("nonpositive_total_r")
        if bm["profit_factor"] <= 1.05:
            fail.append("profit_factor_le_1_05")
        if m20["total_r"] <= 0:
            fail.append("fails_2x_cost_stress")
        if len(folds) != 2:
            fail.append("independent_year_count_not_2")
        if positive_fold_rate < 1.0:
            fail.append("not_positive_in_both_independent_years")
        if worst_p05 <= 0:
            fail.append("dependent_mc_2x_p05_nonpositive")
        if worst_ruin > 0.01:
            fail.append("capital_aware_ruin_gt_1pct")
        if dsr3["probability"] < 0.95:
            fail.append("dsr_3_portfolios_below_095")
        results.append({
            "portfolio_id": p["portfolio_id"],
            "scheme": p["scheme"],
            "component_count": p["component_count"],
            "baseline": bm,
            "cost_stress_1_5x": metrics(s15),
            "cost_stress_2x": m20,
            "year_folds": folds,
            "positive_year_rate": positive_fold_rate,
            "dependent_block_mc_2x_cost": mcs,
            "worst_mc_p05_total_r": worst_p05,
            "worst_capital_drawdown_breach_probability": worst_ruin,
            "dsr_portfolio_trials_3": dsr3,
            "dsr_trials_8_diagnostic": dsr8_diag,
            "quarter_total_r": dict(sorted(quarter_vals.items())),
            "pre_pbo_independent_pass": not fail,
            "fail_reasons": fail,
            "components": p["components"],
        })

    qlabels = sorted({q for r in results for q in r["quarter_total_r"]})
    matrix = [[r["quarter_total_r"].get(q, 0.0) for r in results] for q in qlabels]
    pbo = cscv_pbo(matrix)
    pbo_pass = bool(pbo.get("available") and float(pbo.get("pbo", 1.0)) <= PBO_MAX)
    for r in results:
        r["independent_pbo_pass"] = pbo_pass
        r["independent_validation_pass"] = bool(r["pre_pbo_independent_pass"] and pbo_pass)

    summary = {
        "audit": "LONG_PORTFOLIO_INDEPENDENT_2018_2019_V1",
        "source_frozen_portfolio_run": 34781565340,
        "tested_portfolios": [r["portfolio_id"] for r in results],
        "independent_window": f"{INDEPENDENT_START}/{INDEPENDENT_END}",
        "why_independent": "This 2018-2019 window was not used in Phase 2 discovery, the 2022-2025 confirmatory regime tests, or the prior portfolio formation/robustness.",
        "pre_pbo_survivors": sum(r["pre_pbo_independent_pass"] for r in results),
        "long_pbo": pbo,
        "long_pbo_pass": pbo_pass,
        "final_independent_survivors": sum(r["independent_validation_pass"] for r in results),
        "survivor_ids": [r["portfolio_id"] for r in results if r["independent_validation_pass"]],
        "gates": {
            "active_days_min": 60,
            "profit_factor_gt": 1.05,
            "2x_cost_total_r_gt_0": True,
            "both_independent_years_positive": True,
            "moving_block_mc_2x_p05_gt_0": True,
            "capital_dd_10pct_breach_probability_max": 0.01,
            "dsr_trials_3_min": 0.95,
            "pbo_max": PBO_MAX,
        },
        "guardrails": [
            "No component or weight changes are allowed in this test.",
            "B/C definitions are unchanged.",
            "No thresholds are chosen from 2018-2019 results.",
            "The sealed final holdout 2020-01-02/2022-08-31 is not read.",
            "A pass here still does not authorize live trading.",
            "LIVE MONEY=false.",
        ],
    }
    OUT.mkdir(exist_ok=True)
    (OUT / "long_portfolio_independent_validation.json").write_text(
        json.dumps({"summary": summary, "portfolios": results}, indent=2), encoding="utf-8"
    )
    (OUT / "long_portfolio_independent_validation_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    print("LONG_PORTFOLIO_INDEPENDENT_VALIDATION_OK")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
