"""RR-sharded Phase 3 Risk Gate V2 calculator.

This is a compute-only resiliency repair. It reads the already cached confirmatory
market window, evaluates one RR slice, and writes candidate-level evidence.
Statistical criteria are intentionally identical to phase3_risk_gate_v2.py.
The reserved 2020-01-02..2022-08-31 holdout is never queried.
"""

from __future__ import annotations

import json
import math
import os
from pathlib import Path

import pandas as pd

import real_strategy_discovery as base
import phase3_risk_gate_v2 as v2
from coalition_backtester import CoalitionBacktester
from phase2_historical_search import fast_build_events
from phase3_multiyear_validation import (
    BASELINE_COST_R,
    MIN_ELIGIBLE_FOLDS,
    MIN_FOLD_TRADES,
    MIN_FULL_TRADES,
    MIN_POSITIVE_FOLD_RATE,
    candidate_key,
    context_from_candidate,
    direction_value,
    freeze_exact_intersection,
    metrics,
)


def _label(rr: float) -> str:
    return str(rr).replace(".", "p")


def main() -> None:
    symbol = os.getenv("PHASE3_SYMBOL", "ES.v.0").strip()
    rr = float(os.environ["PHASE3_RR_FILTER"])
    cache_path = Path(os.environ["PHASE3_V2_INPUT_PARQUET"])

    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported PHASE3_SYMBOL: {symbol}")
    if v2.PRIMARY_RISK_PROFILE not in v2.RISK_PROFILES:
        raise SystemExit(f"Unknown PRIMARY_RISK_PROFILE: {v2.PRIMARY_RISK_PROFILE}")
    if not cache_path.exists():
        raise SystemExit(f"Cached Phase 3 parquet missing: {cache_path}")

    frozen_all = freeze_exact_intersection(symbol)
    indexed = [(idx, row) for idx, row in enumerate(frozen_all, start=1) if float(row["rr"]) == rr]

    out = Path("phase3_risk_gate_v2_shards")
    out.mkdir(exist_ok=True)
    target = out / f"rr_{_label(rr)}.json"

    if not indexed:
        target.write_text(
            json.dumps({"symbol": symbol, "rr": rr, "quarters": [], "candidates": []}, indent=2),
            encoding="utf-8",
        )
        print(f"PHASE3_V2_RR_SHARD_EMPTY symbol={symbol} rr={rr}", flush=True)
        return

    df = pd.read_parquet(cache_path)
    idx = pd.DatetimeIndex(df.index)
    if idx.tz is None:
        idx = idx.tz_localize("UTC")
    work = df.copy()
    work["local_time"] = idx.tz_convert(base.TZ)
    work = work.sort_values("local_time")
    work = work[~work.index.duplicated(keep="first")].copy()
    enriched = base.enrich_symbol(work)
    enriched["year"] = enriched["local_time"].dt.year
    enriched["quarter"] = enriched["local_time"].dt.to_period("Q").astype(str)

    years = sorted(int(x) for x in enriched["year"].unique())
    quarters = sorted(str(x) for x in enriched["quarter"].unique())
    backtester = CoalitionBacktester()

    full_events = fast_build_events(enriched, symbol, rr, BASELINE_COST_R)
    year_events = {
        year: fast_build_events(enriched[enriched["year"] == year].copy(), symbol, rr, BASELINE_COST_R)
        for year in years
    }
    quarter_events = {
        quarter: fast_build_events(enriched[enriched["quarter"] == quarter].copy(), symbol, rr, BASELINE_COST_R)
        for quarter in quarters
    }
    print(
        f"PHASE3_V2_RR_DATA symbol={symbol} rr={rr} events={len(full_events)} candidates={len(indexed)}",
        flush=True,
    )

    results = []
    for global_index, candidate in indexed:
        direction = direction_value(candidate["direction"])
        context = context_from_candidate(candidate)
        members = candidate["members"]
        returns_r = backtester.returns_for(full_events, members, direction, context=context)
        baseline = metrics(returns_r)
        stressed_15 = [x - BASELINE_COST_R * 0.5 for x in returns_r]
        stressed_20 = [x - BASELINE_COST_R for x in returns_r]

        fold_metrics = []
        eligible_folds = []
        for year in years:
            fold_returns = backtester.returns_for(year_events[year], members, direction, context=context)
            fold = metrics(fold_returns)
            fold["year"] = year
            fold["eligible"] = len(fold_returns) >= MIN_FOLD_TRADES
            fold_metrics.append(fold)
            if fold["eligible"]:
                eligible_folds.append(fold)
        positive_fold_rate = (
            sum(1 for x in eligible_folds if x["expectancy_r"] > 0) / len(eligible_folds)
            if eligible_folds else 0.0
        )

        block_tests = [
            v2.dependent_block_mc(
                returns_r,
                block_length,
                iterations=v2.MC_ITERATIONS,
                seed=71 + global_index,
            )
            for block_length in v2.BLOCK_LENGTHS
        ]
        valid_blocks = [x for x in block_tests if x is not None]
        worst_block_p05 = min((x["p05_total_r"] for x in valid_blocks), default=-math.inf)
        worst_primary_ruin = max(
            (
                x["risk_profiles"][v2.PRIMARY_RISK_PROFILE]["ruin_probability"]
                for x in valid_blocks
            ),
            default=1.0,
        )
        worst_primary_p99_capital_dd = max(
            (
                x["risk_profiles"][v2.PRIMARY_RISK_PROFILE]["p99_capital_max_drawdown"]
                for x in valid_blocks
            ),
            default=1.0,
        )

        dsr_survivor_pool = v2.deflated_sharpe_probability(returns_r, v2.SURVIVOR_POOL_TRIALS)
        dsr_full_search_upper_bound = v2.deflated_sharpe_probability(
            returns_r, v2.FULL_SEARCH_TRIAL_UPPER_BOUND
        )

        quarter_totals = []
        for quarter in quarters:
            q_returns = backtester.returns_for(quarter_events[quarter], members, direction, context=context)
            quarter_totals.append(sum(q_returns))

        core_fail = []
        if baseline["trades"] < MIN_FULL_TRADES:
            core_fail.append("insufficient_full_trades")
        if baseline["expectancy_r"] <= 0:
            core_fail.append("nonpositive_baseline_expectancy")
        if baseline["profit_factor"] <= 1.05:
            core_fail.append("profit_factor_le_1_05")
        if metrics(stressed_20)["expectancy_r"] <= 0:
            core_fail.append("fails_2x_cost_stress")
        if len(eligible_folds) < MIN_ELIGIBLE_FOLDS:
            core_fail.append("insufficient_time_folds")
        if positive_fold_rate < MIN_POSITIVE_FOLD_RATE:
            core_fail.append("unstable_time_folds")

        risk_fail = []
        if worst_block_p05 <= 0:
            risk_fail.append("dependent_mc_p05_nonpositive")
        if worst_primary_ruin > v2.MAX_RUIN_PROB:
            risk_fail.append("capital_aware_ruin_gt_1pct")

        selection_fail = []
        if dsr_survivor_pool["probability"] < v2.DSR_THRESHOLD:
            selection_fail.append("dsr_survivor_pool_below_threshold")

        results.append(
            {
                **candidate,
                "candidate_key": candidate_key(candidate),
                "global_frozen_index": global_index,
                "baseline": baseline,
                "cost_stress_1_5x": metrics(stressed_15),
                "cost_stress_2x": metrics(stressed_20),
                "time_folds": fold_metrics,
                "eligible_folds": len(eligible_folds),
                "positive_fold_rate": positive_fold_rate,
                "dependent_block_monte_carlo": valid_blocks,
                "worst_block_p05_total_r": worst_block_p05,
                "primary_risk_profile": v2.PRIMARY_RISK_PROFILE,
                "worst_primary_ruin_probability": worst_primary_ruin,
                "worst_primary_p99_capital_drawdown": worst_primary_p99_capital_dd,
                "dsr_survivor_pool": dsr_survivor_pool,
                "dsr_full_search_upper_bound": dsr_full_search_upper_bound,
                "core_edge_pass": not core_fail,
                "risk_gate_v2_pass": not risk_fail,
                "selection_bias_pass": not selection_fail,
                "core_fail_reasons": core_fail,
                "risk_fail_reasons": risk_fail,
                "selection_fail_reasons": selection_fail,
                "quarter_total_r": dict(zip(quarters, quarter_totals)),
            }
        )

    payload = {
        "phase": "3_RISK_GATE_V2_RR_SHARD",
        "symbol": symbol,
        "rr": rr,
        "rows_downloaded": len(enriched),
        "validation_start": v2.VALIDATION_START,
        "validation_end": v2.VALIDATION_END,
        "reserved_untouched_holdout": "2020-01-02/2022-08-31",
        "quarters": quarters,
        "candidates": results,
    }
    target.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"PHASE3_V2_RR_SHARD_OK symbol={symbol} rr={rr} candidates={len(results)}", flush=True)


if __name__ == "__main__":
    main()
