"""Robustness audit for frozen ACTIVE_RESEARCH A/B/C candidates.

This script does NOT discover, tune, or promote new rules. It replays the exact
REGIME_ABCD_V1 B/C rules on the already-used confirmatory window and adds frozen
robustness checks: cost stress, yearly folds, dependent moving-block Monte Carlo,
DSR, and market-level CSCV-style PBO. The reserved 2020-01-02..2022-08-31
holdout is never requested or read here. Research only; cannot enable paper/live.
"""

from __future__ import annotations

import json
import math
import os
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd

import real_strategy_discovery as base
from phase2_historical_search import _trade_outcome_arrays
from phase3_multiyear_validation import BASELINE_COST_R, metrics
from phase3_risk_gate_v2 import (
    BLOCK_LENGTHS,
    DSR_THRESHOLD,
    FULL_SEARCH_TRIAL_UPPER_BOUND,
    MAX_RUIN_PROB,
    PBO_MAX,
    PRIMARY_RISK_PROFILE,
    SURVIVOR_POOL_TRIALS,
    cscv_pbo,
    deflated_sharpe_probability,
    dependent_block_mc,
)

MIN_TRADES = 60
MIN_FOLD_TRADES = 5
MIN_FOLDS = 3
MIN_POSITIVE_FOLD_RATE = 0.60


def _direction_value(value) -> int:
    if isinstance(value, str):
        return 1 if value.upper() == "LONG" else -1
    return 1 if int(value) > 0 else -1


def _candidate_key(row: dict) -> str:
    return str(row.get("candidate_key") or f"{row.get('direction')}|{'+'.join(row.get('members', []))}|{row.get('rr')}")


def _safe_metrics(values):
    return metrics([float(x) for x in values])


def _build_features(df: pd.DataFrame) -> pd.DataFrame:
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
    g["trend_efficiency_threshold"] = (
        g["trend_efficiency20"].rolling(120, min_periods=60).median().shift(1)
    )

    prior_atr = atr.shift(10)
    g["vol_slope"] = (atr - prior_atr) / prior_atr.replace(0.0, np.nan)
    g["vol_accel"] = g["vol_slope"] - g["vol_slope"].shift(10)
    prior_vol_mean = g["volume"].astype(float).rolling(20, min_periods=10).mean().shift(1)
    g["relative_volume"] = g["volume"].astype(float) / prior_vol_mean.replace(0.0, np.nan)

    prior_vol_target = g["atr60_med"].shift(1)
    g["risk_scale"] = (prior_vol_target / atr.replace(0.0, np.nan)).clip(lower=0.25, upper=1.0)
    g["year"] = g["local_time"].dt.year.astype(int)
    g["quarter"] = g["local_time"].dt.to_period("Q").astype(str)
    return g


def main() -> None:
    symbol = os.environ["PHASE3_SYMBOL"].strip()
    cache_path = Path(os.environ["PHASE3_V2_INPUT_PARQUET"])
    selected_path = Path(os.environ["ACTIVE_CANDIDATES_JSON"])
    if not cache_path.exists():
        raise SystemExit(f"Missing market checkpoint: {cache_path}")
    if not selected_path.exists():
        raise SystemExit(f"Missing frozen candidate evidence: {selected_path}")

    all_selected = json.loads(selected_path.read_text(encoding="utf-8"))
    active = [row for row in all_selected if row.get("lifecycle_research_state") == "ACTIVE_RESEARCH"]
    if not active:
        raise SystemExit(f"No ACTIVE_RESEARCH candidates for {symbol}")
    if any(row.get("symbol") not in (None, symbol) for row in active):
        raise SystemExit("Candidate artifact symbol mismatch")

    g = _build_features(pd.read_parquet(cache_path))
    local_times = g["local_time"].tolist()
    session_arr = np.array([base.session_label(ts) for ts in local_times], dtype=object)
    bucket_arr = np.array([base.open_bucket(ts) for ts in local_times], dtype=object)
    vol_regime = g["vol_regime"].astype(str).to_numpy()
    trend_regime = g["trend_regime"].astype(str).to_numpy()
    structure_regime = g["structure_regime"].astype(str).to_numpy()
    signal_arrays = {
        name: g[f"sig_{name}"].fillna(0).astype(int).to_numpy()
        for name in base.STRATEGIES
    }

    open_ = g["open"].astype(float).to_numpy()
    high = g["high"].astype(float).to_numpy()
    low = g["low"].astype(float).to_numpy()
    close_arr = g["close"].astype(float).to_numpy()
    atr_arr = g["atr14"].astype(float).to_numpy()
    sf = g["slope_fast_atr"].to_numpy()
    sm = g["slope_medium_atr"].to_numpy()
    ss = g["slope_slow_atr"].to_numpy()
    eff = g["trend_efficiency20"].to_numpy()
    eff_thr = g["trend_efficiency_threshold"].to_numpy()
    risk_scale = g["risk_scale"].to_numpy()
    years = g["year"].to_numpy()
    quarters = g["quarter"].astype(str).to_numpy()
    quarter_labels = sorted(set(str(x) for x in quarters))

    results = []
    quarter_columns = []

    for index, candidate in enumerate(active, start=1):
        direction = _direction_value(candidate["direction"])
        rr = float(candidate["rr"])
        context = candidate["context"]
        members = candidate["members"]

        mask = (
            (session_arr == context["session"])
            & (bucket_arr == context["minutes_from_open_bucket"])
            & (vol_regime == context["volatility_regime"])
            & (trend_regime == context["trend_regime"])
            & (structure_regime == context["structure_regime"])
        )
        for member in members:
            mask &= signal_arrays[member] == direction

        c_returns = []
        c_scales = []
        c_years = []
        c_quarters = []
        for pos in np.flatnonzero(mask):
            if pos + 1 >= len(g) or not math.isfinite(float(atr_arr[pos])) or atr_arr[pos] <= 0:
                continue
            gross = _trade_outcome_arrays(open_, high, low, close_arr, atr_arr, int(pos), direction, rr)
            if gross is None:
                continue

            slopes = (sf[pos], sm[pos], ss[pos])
            directional_votes = sum(
                1 for value in slopes
                if math.isfinite(float(value)) and direction * float(value) > 0.0
            )
            quality_ok = (
                math.isfinite(float(eff[pos]))
                and math.isfinite(float(eff_thr[pos]))
                and float(eff[pos]) >= float(eff_thr[pos])
            )
            if directional_votes < 2 or not quality_ok:
                continue

            scale = float(risk_scale[pos]) if math.isfinite(float(risk_scale[pos])) else 1.0
            scale = min(1.0, max(0.25, scale))
            c_returns.append((float(gross) - BASELINE_COST_R) * scale)
            c_scales.append(scale)
            c_years.append(int(years[pos + 1]))
            c_quarters.append(str(quarters[pos + 1]))

        base_metrics = _safe_metrics(c_returns)
        stress_15 = [ret - 0.5 * BASELINE_COST_R * scale for ret, scale in zip(c_returns, c_scales)]
        stress_20 = [ret - 1.0 * BASELINE_COST_R * scale for ret, scale in zip(c_returns, c_scales)]
        stress_15_metrics = _safe_metrics(stress_15)
        stress_20_metrics = _safe_metrics(stress_20)

        fold_rows = []
        eligible = []
        for year in sorted(set(c_years)):
            vals = [ret for ret, y in zip(c_returns, c_years) if y == year]
            row = _safe_metrics(vals)
            row["year"] = int(year)
            row["eligible"] = len(vals) >= MIN_FOLD_TRADES
            fold_rows.append(row)
            if row["eligible"]:
                eligible.append(row)
        positive_fold_rate = (
            sum(1 for row in eligible if row["expectancy_r"] > 0) / len(eligible)
            if eligible else 0.0
        )

        block_tests = [
            dependent_block_mc(c_returns, block, iterations=2000, seed=7000 + index)
            for block in BLOCK_LENGTHS
        ]
        block_tests = [x for x in block_tests if x is not None]
        worst_p05 = min((x["p05_total_r"] for x in block_tests), default=-math.inf)
        worst_ruin = max(
            (x["risk_profiles"][PRIMARY_RISK_PROFILE]["ruin_probability"] for x in block_tests),
            default=1.0,
        )
        worst_p99_dd = max(
            (x["risk_profiles"][PRIMARY_RISK_PROFILE]["p99_capital_max_drawdown"] for x in block_tests),
            default=1.0,
        )

        dsr_165 = deflated_sharpe_probability(c_returns, SURVIVOR_POOL_TRIALS)
        dsr_full = deflated_sharpe_probability(c_returns, FULL_SEARCH_TRIAL_UPPER_BOUND)
        quarter_totals = {
            q: float(sum(ret for ret, rq in zip(c_returns, c_quarters) if rq == q))
            for q in quarter_labels
        }
        quarter_columns.append([quarter_totals[q] for q in quarter_labels])

        fail = []
        if base_metrics["trades"] < MIN_TRADES:
            fail.append("insufficient_trades")
        if base_metrics["expectancy_r"] <= 0:
            fail.append("nonpositive_expectancy")
        if base_metrics["profit_factor"] <= 1.05:
            fail.append("profit_factor_le_1_05")
        if stress_20_metrics["expectancy_r"] <= 0:
            fail.append("fails_2x_cost_stress")
        if len(eligible) < MIN_FOLDS:
            fail.append("insufficient_year_folds")
        if positive_fold_rate < MIN_POSITIVE_FOLD_RATE:
            fail.append("unstable_year_folds")
        if worst_p05 <= 0:
            fail.append("dependent_mc_p05_nonpositive")
        if worst_ruin > MAX_RUIN_PROB:
            fail.append("capital_aware_ruin_gt_1pct")
        if dsr_165["probability"] < DSR_THRESHOLD:
            fail.append("dsr_165_below_095")

        results.append({
            "symbol": symbol,
            "candidate_key": _candidate_key(candidate),
            "direction": candidate["direction"],
            "members": members,
            "rr": rr,
            "context": context,
            "selection_state": "ACTIVE_RESEARCH_FROZEN",
            "variant_c_metrics": base_metrics,
            "cost_stress_1_5x": stress_15_metrics,
            "cost_stress_2x": stress_20_metrics,
            "year_folds": fold_rows,
            "eligible_year_folds": len(eligible),
            "positive_fold_rate": positive_fold_rate,
            "dependent_block_mc": block_tests,
            "worst_mc_p05_total_r": worst_p05,
            "primary_risk_profile": PRIMARY_RISK_PROFILE,
            "worst_primary_ruin_probability": worst_ruin,
            "worst_primary_p99_capital_drawdown": worst_p99_dd,
            "dsr_165": dsr_165,
            "dsr_full_search_upper_bound": dsr_full,
            "quarter_total_r": quarter_totals,
            "candidate_robustness_pass_pre_pbo": not fail,
            "candidate_fail_reasons": fail,
            "source_variant_a": candidate.get("variant_a_base"),
            "source_variant_b": candidate.get("variant_b_regime"),
            "source_variant_c": candidate.get("variant_c_vol_target"),
        })

    # CSCV expects periods x candidates; quarter_columns is candidates x periods.
    performance_matrix = [
        [quarter_columns[c][p] for c in range(len(quarter_columns))]
        for p in range(len(quarter_labels))
    ] if quarter_columns else []
    pbo = cscv_pbo(performance_matrix)
    pbo_pass = bool(pbo.get("available") and float(pbo.get("pbo", 1.0)) <= PBO_MAX)
    for row in results:
        row["market_pbo_pass"] = pbo_pass
        row["robustness_pass"] = bool(row["candidate_robustness_pass_pre_pbo"] and pbo_pass)

    summary = {
        "audit": "REGIME_ACTIVE_ROBUSTNESS_V1",
        "symbol": symbol,
        "validation_window_reused": "2022-09-01/2025-09-24",
        "reserved_untouched_holdout": "2020-01-02/2022-08-31",
        "important_limitation": "This is a robustness audit on the same confirmatory window used to label ACTIVE_RESEARCH; it is not a new independent OOS test.",
        "active_candidates_frozen": len(results),
        "pre_pbo_robust_survivors": sum(1 for r in results if r["candidate_robustness_pass_pre_pbo"]),
        "market_pbo": pbo,
        "market_pbo_pass": pbo_pass,
        "robust_survivors": sum(1 for r in results if r["robustness_pass"]),
        "gates": {
            "min_trades": MIN_TRADES,
            "expectancy_gt_0": True,
            "profit_factor_gt": 1.05,
            "2x_cost_expectancy_gt_0": True,
            "min_eligible_year_folds": MIN_FOLDS,
            "min_positive_fold_rate": MIN_POSITIVE_FOLD_RATE,
            "dependent_mc_p05_gt_0": True,
            "max_capital_drawdown_breach_probability": MAX_RUIN_PROB,
            "dsr_165_probability_min": DSR_THRESHOLD,
            "market_pbo_max": PBO_MAX,
        },
        "research_guardrails": [
            "B/C feature definitions are identical to REGIME_ABCD_V1 and are not re-tuned here.",
            "Only candidates already labeled ACTIVE_RESEARCH before this audit are included.",
            "The 2020-01-02/2022-08-31 final holdout is not read.",
            "No result from this audit authorizes paper or live trading.",
            "LIVE MONEY remains false.",
        ],
    }

    out = Path("active_robustness_output")
    out.mkdir(exist_ok=True)
    safe_symbol = symbol.replace("/", "_")
    (out / f"active_robustness_{safe_symbol}.json").write_text(
        json.dumps({"summary": summary, "candidates": results}, indent=2), encoding="utf-8"
    )
    print("REGIME_ACTIVE_ROBUSTNESS_OK", flush=True)
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
