import json
import math
import os
import random
from datetime import date
from itertools import combinations
from pathlib import Path
from statistics import NormalDist, mean, pstdev

import databento as db
import pandas as pd

import real_strategy_discovery as base
from coalition_backtester import CoalitionBacktester
from phase2_historical_search import fast_build_events
from phase3_multiyear_validation import (
    BASELINE_COST_R,
    MIN_ELIGIBLE_FOLDS,
    MIN_FOLD_TRADES,
    MIN_FULL_TRADES,
    MIN_POSITIVE_FOLD_RATE,
    VALIDATION_END,
    VALIDATION_START,
    candidate_key,
    context_from_candidate,
    direction_value,
    freeze_exact_intersection,
    metrics,
)
from robustness_engine import max_drawdown_r


MC_ITERATIONS = int(os.getenv("PHASE3_V2_MC_ITERATIONS", "2000"))
BLOCK_LENGTHS = tuple(int(x) for x in os.getenv("PHASE3_V2_BLOCK_LENGTHS", "5,20").split(","))
CAPITAL_DD_BUDGET = float(os.getenv("PHASE3_V2_CAPITAL_DD_BUDGET", "0.10"))
RISK_PROFILES = {
    "conservative_025pct": 0.0025,
    "balanced_050pct": 0.0050,
    "strict_100pct": 0.0100,
}
PRIMARY_RISK_PROFILE = os.getenv("PHASE3_V2_PRIMARY_PROFILE", "conservative_025pct")
MAX_RUIN_PROB = float(os.getenv("PHASE3_V2_MAX_RUIN_PROB", "0.01"))
DSR_THRESHOLD = float(os.getenv("PHASE3_V2_DSR_THRESHOLD", "0.95"))
SURVIVOR_POOL_TRIALS = int(os.getenv("PHASE3_V2_SURVIVOR_POOL_TRIALS", "165"))
FULL_SEARCH_TRIAL_UPPER_BOUND = int(os.getenv("PHASE3_V2_FULL_SEARCH_TRIALS", "833140"))
PBO_MAX = float(os.getenv("PHASE3_V2_PBO_MAX", "0.50"))


def percentile(values, q):
    if not values:
        return 0.0
    ordered = sorted(values)
    if len(ordered) == 1:
        return ordered[0]
    pos = (len(ordered) - 1) * q
    lo = int(pos)
    hi = min(lo + 1, len(ordered) - 1)
    w = pos - lo
    return ordered[lo] * (1.0 - w) + ordered[hi] * w


def sample_moving_blocks(values, block_length, rng):
    n = len(values)
    if n == 0:
        return []
    block_length = max(1, min(int(block_length), n))
    path = []
    max_start = max(0, n - block_length)
    while len(path) < n:
        start = rng.randint(0, max_start) if max_start else 0
        path.extend(values[start : start + block_length])
    return path[:n]


def capital_max_drawdown(path, risk_fraction):
    equity = 1.0
    peak = 1.0
    worst = 0.0
    for r_value in path:
        step = 1.0 + risk_fraction * r_value
        if step <= 0.0:
            return 1.0
        equity *= step
        peak = max(peak, equity)
        if peak > 0:
            worst = max(worst, 1.0 - equity / peak)
    return worst


def dependent_block_mc(returns_r, block_length, iterations=MC_ITERATIONS, seed=71):
    if not returns_r:
        return None
    rng = random.Random(seed + int(block_length) * 101)
    totals = []
    drawdowns_r = []
    capital_dd = {name: [] for name in RISK_PROFILES}
    ruin_hits = {name: 0 for name in RISK_PROFILES}

    for _ in range(iterations):
        sampled = sample_moving_blocks(returns_r, block_length, rng)
        stressed = []
        for value in sampled:
            if rng.random() < 0.05:
                continue
            stressed.append(value - 0.5 * BASELINE_COST_R + rng.gauss(0.0, 0.03))
        if not stressed:
            stressed = [-BASELINE_COST_R]
        totals.append(sum(stressed))
        drawdowns_r.append(max_drawdown_r(stressed))
        for profile, risk_fraction in RISK_PROFILES.items():
            dd = capital_max_drawdown(stressed, risk_fraction)
            capital_dd[profile].append(dd)
            if dd >= CAPITAL_DD_BUDGET:
                ruin_hits[profile] += 1

    profiles = {}
    for profile, risk_fraction in RISK_PROFILES.items():
        profiles[profile] = {
            "risk_fraction_per_1r": risk_fraction,
            "capital_drawdown_budget": CAPITAL_DD_BUDGET,
            "ruin_probability": ruin_hits[profile] / iterations,
            "median_capital_max_drawdown": percentile(capital_dd[profile], 0.50),
            "p95_capital_max_drawdown": percentile(capital_dd[profile], 0.95),
            "p99_capital_max_drawdown": percentile(capital_dd[profile], 0.99),
        }

    return {
        "iterations": iterations,
        "block_length": block_length,
        "profitable_probability": sum(1 for x in totals if x > 0) / iterations,
        "median_total_r": percentile(totals, 0.50),
        "p05_total_r": percentile(totals, 0.05),
        "median_max_drawdown_r": percentile(drawdowns_r, 0.50),
        "p95_max_drawdown_r": percentile(drawdowns_r, 0.95),
        "p99_max_drawdown_r": percentile(drawdowns_r, 0.99),
        "risk_profiles": profiles,
    }


def sample_moments(values):
    n = len(values)
    if n < 3:
        return 0.0, 3.0
    mu = mean(values)
    diffs = [x - mu for x in values]
    m2 = sum(x * x for x in diffs) / n
    if m2 <= 0:
        return 0.0, 3.0
    m3 = sum(x ** 3 for x in diffs) / n
    m4 = sum(x ** 4 for x in diffs) / n
    skew = m3 / (m2 ** 1.5)
    kurtosis = m4 / (m2 * m2)
    return skew, kurtosis


def deflated_sharpe_probability(returns_r, n_trials):
    n = len(returns_r)
    if n < 3:
        return {
            "trades": n,
            "sharpe_per_trade": 0.0,
            "benchmark_sharpe": None,
            "probability": 0.0,
            "n_trials": int(n_trials),
        }
    sigma = pstdev(returns_r)
    if sigma <= 0:
        sr = 999.0 if mean(returns_r) > 0 else 0.0
    else:
        sr = mean(returns_r) / sigma
    skew, kurtosis = sample_moments(returns_r)
    variance_term = max(
        1e-12,
        1.0 - skew * sr + ((kurtosis - 1.0) / 4.0) * (sr ** 2),
    )
    sr_std = math.sqrt(variance_term / max(1, n - 1))

    normal = NormalDist()
    trials = max(2, int(n_trials))
    gamma = 0.5772156649015329
    q1 = min(1.0 - 1e-12, max(1e-12, 1.0 - 1.0 / trials))
    q2 = min(1.0 - 1e-12, max(1e-12, 1.0 - 1.0 / (trials * math.e)))
    expected_max_null = sr_std * (
        (1.0 - gamma) * normal.inv_cdf(q1) + gamma * normal.inv_cdf(q2)
    )
    z = (sr - expected_max_null) / max(sr_std, 1e-12)
    probability = normal.cdf(z)
    return {
        "trades": n,
        "sharpe_per_trade": sr,
        "skewness": skew,
        "kurtosis": kurtosis,
        "sharpe_standard_error": sr_std,
        "benchmark_sharpe": expected_max_null,
        "probability": probability,
        "n_trials": trials,
    }


def cscv_pbo(performance_matrix):
    # performance_matrix is ordered periods x candidates, using period total R.
    if not performance_matrix or len(performance_matrix) < 6:
        return {"available": False, "reason": "insufficient_periods"}
    candidate_count = len(performance_matrix[0])
    if candidate_count < 2:
        return {"available": False, "reason": "insufficient_candidates"}
    periods = len(performance_matrix)
    use_periods = periods if periods % 2 == 0 else periods - 1
    matrix = performance_matrix[:use_periods]
    half = use_periods // 2
    overfit = 0
    splits = 0
    selected_oos_percentiles = []

    for train_idx_tuple in combinations(range(use_periods), half):
        train_idx = set(train_idx_tuple)
        test_idx = [i for i in range(use_periods) if i not in train_idx]
        train_scores = [
            sum(matrix[i][j] for i in train_idx) / half
            for j in range(candidate_count)
        ]
        winner = max(range(candidate_count), key=lambda j: train_scores[j])
        test_scores = [
            sum(matrix[i][j] for i in test_idx) / half
            for j in range(candidate_count)
        ]
        order = sorted(range(candidate_count), key=lambda j: test_scores[j], reverse=True)
        rank = order.index(winner)
        percentile_rank = rank / max(1, candidate_count - 1)
        selected_oos_percentiles.append(percentile_rank)
        if percentile_rank > 0.50:
            overfit += 1
        splits += 1

    return {
        "available": True,
        "periods": use_periods,
        "candidates": candidate_count,
        "splits": splits,
        "pbo": overfit / splits if splits else 1.0,
        "median_selected_oos_percentile_rank": percentile(selected_oos_percentiles, 0.50),
    }


def main():
    api_key = os.getenv("DATABENTO_API_KEY", "")
    if not api_key:
        raise SystemExit("DATABENTO_API_KEY secret is missing")

    symbol = os.getenv("PHASE3_SYMBOL", "").strip()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported PHASE3_SYMBOL: {symbol}")
    if PRIMARY_RISK_PROFILE not in RISK_PROFILES:
        raise SystemExit(f"Unknown PRIMARY_RISK_PROFILE: {PRIMARY_RISK_PROFILE}")

    frozen = freeze_exact_intersection(symbol)
    if not frozen:
        raise SystemExit(f"No frozen Phase 2 survivors for {symbol}")

    start_date = date.fromisoformat(VALIDATION_START)
    end_date = date.fromisoformat(VALIDATION_END)
    client = db.Historical(api_key)
    data = client.timeseries.get_range(
        dataset="GLBX.MDP3",
        schema="ohlcv-1m",
        stype_in="continuous",
        symbols=[symbol],
        start=base.utc_iso(start_date, 18, 0),
        end=base.utc_iso(end_date, 16, 0),
    )
    df = data.to_df()
    if df.empty:
        raise SystemExit("No Databento rows returned for Phase 3 V2")

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
    rrs = sorted({float(row["rr"]) for row in frozen})
    backtester = CoalitionBacktester()

    full_events = {}
    year_events = {}
    quarter_events = {}
    for rr in rrs:
        full_events[rr] = fast_build_events(enriched, symbol, rr, BASELINE_COST_R)
        year_events[rr] = {}
        for year in years:
            frame = enriched[enriched["year"] == year].copy()
            year_events[rr][year] = fast_build_events(frame, symbol, rr, BASELINE_COST_R)
        quarter_events[rr] = {}
        for quarter in quarters:
            frame = enriched[enriched["quarter"] == quarter].copy()
            quarter_events[rr][quarter] = fast_build_events(frame, symbol, rr, BASELINE_COST_R)
        print(
            f"PHASE3_V2_DATA symbol={symbol} rr={rr} events={len(full_events[rr])}",
            flush=True,
        )

    results = []
    quarter_per_candidate = []

    for index, candidate in enumerate(frozen, start=1):
        rr = float(candidate["rr"])
        direction = direction_value(candidate["direction"])
        context = context_from_candidate(candidate)
        members = candidate["members"]
        returns_r = backtester.returns_for(full_events[rr], members, direction, context=context)
        baseline = metrics(returns_r)
        stressed_15 = [x - BASELINE_COST_R * 0.5 for x in returns_r]
        stressed_20 = [x - BASELINE_COST_R for x in returns_r]

        fold_metrics = []
        eligible_folds = []
        for year in years:
            fold_returns = backtester.returns_for(
                year_events[rr][year], members, direction, context=context
            )
            fold = metrics(fold_returns)
            fold["year"] = year
            fold["eligible"] = len(fold_returns) >= MIN_FOLD_TRADES
            fold_metrics.append(fold)
            if fold["eligible"]:
                eligible_folds.append(fold)
        positive_fold_rate = (
            sum(1 for x in eligible_folds if x["expectancy_r"] > 0) / len(eligible_folds)
            if eligible_folds
            else 0.0
        )

        block_tests = []
        for block_length in BLOCK_LENGTHS:
            block_tests.append(
                dependent_block_mc(
                    returns_r,
                    block_length,
                    iterations=MC_ITERATIONS,
                    seed=71 + index,
                )
            )
        valid_blocks = [x for x in block_tests if x is not None]
        worst_block_p05 = min((x["p05_total_r"] for x in valid_blocks), default=-math.inf)
        worst_primary_ruin = max(
            (
                x["risk_profiles"][PRIMARY_RISK_PROFILE]["ruin_probability"]
                for x in valid_blocks
            ),
            default=1.0,
        )
        worst_primary_p99_capital_dd = max(
            (
                x["risk_profiles"][PRIMARY_RISK_PROFILE]["p99_capital_max_drawdown"]
                for x in valid_blocks
            ),
            default=1.0,
        )

        dsr_survivor_pool = deflated_sharpe_probability(returns_r, SURVIVOR_POOL_TRIALS)
        dsr_full_search_upper_bound = deflated_sharpe_probability(
            returns_r, FULL_SEARCH_TRIAL_UPPER_BOUND
        )

        quarter_totals = []
        for quarter in quarters:
            quarter_returns = backtester.returns_for(
                quarter_events[rr][quarter], members, direction, context=context
            )
            quarter_totals.append(sum(quarter_returns))
        quarter_per_candidate.append(quarter_totals)

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
        if worst_primary_ruin > MAX_RUIN_PROB:
            risk_fail.append("capital_aware_ruin_gt_1pct")

        selection_fail = []
        if dsr_survivor_pool["probability"] < DSR_THRESHOLD:
            selection_fail.append("dsr_survivor_pool_below_threshold")

        results.append(
            {
                **candidate,
                "candidate_key": candidate_key(candidate),
                "baseline": baseline,
                "cost_stress_1_5x": metrics(stressed_15),
                "cost_stress_2x": metrics(stressed_20),
                "time_folds": fold_metrics,
                "eligible_folds": len(eligible_folds),
                "positive_fold_rate": positive_fold_rate,
                "dependent_block_monte_carlo": valid_blocks,
                "worst_block_p05_total_r": worst_block_p05,
                "primary_risk_profile": PRIMARY_RISK_PROFILE,
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

        if index % 10 == 0 or index == len(frozen):
            print(
                f"PHASE3_V2_PROGRESS symbol={symbol} tested={index}/{len(frozen)}",
                flush=True,
            )

    performance_matrix = []
    for q_index in range(len(quarters)):
        performance_matrix.append([row[q_index] for row in quarter_per_candidate])
    pbo = cscv_pbo(performance_matrix)
    pbo_pass = bool(pbo.get("available")) and pbo.get("pbo", 1.0) <= PBO_MAX

    for row in results:
        row["symbol_pool_pbo"] = pbo
        row["pbo_pass"] = pbo_pass
        row["phase3_v2_pass"] = (
            row["core_edge_pass"]
            and row["risk_gate_v2_pass"]
            and row["selection_bias_pass"]
            and pbo_pass
        )

    survivors = [row for row in results if row["phase3_v2_pass"]]
    risk_survivors = [
        row for row in results if row["core_edge_pass"] and row["risk_gate_v2_pass"]
    ]
    core_survivors = [row for row in results if row["core_edge_pass"]]

    survivors.sort(
        key=lambda row: (
            row["worst_block_p05_total_r"],
            row["baseline"]["expectancy_r"],
            -row["worst_primary_ruin_probability"],
        ),
        reverse=True,
    )

    out = Path("phase3_risk_gate_v2_output")
    out.mkdir(exist_ok=True)
    summary = {
        "phase": "3_RISK_GATE_V2",
        "symbol": symbol,
        "frozen_candidates": len(frozen),
        "validation_start": VALIDATION_START,
        "validation_end": VALIDATION_END,
        "reserved_untouched_holdout": "2020-01-02/2022-08-31",
        "rows_downloaded": len(enriched),
        "block_lengths": list(BLOCK_LENGTHS),
        "monte_carlo_iterations": MC_ITERATIONS,
        "capital_drawdown_budget": CAPITAL_DD_BUDGET,
        "risk_profiles": RISK_PROFILES,
        "primary_risk_profile": PRIMARY_RISK_PROFILE,
        "max_ruin_probability": MAX_RUIN_PROB,
        "dsr_threshold": DSR_THRESHOLD,
        "survivor_pool_trials_for_dsr": SURVIVOR_POOL_TRIALS,
        "full_search_trials_upper_bound": FULL_SEARCH_TRIAL_UPPER_BOUND,
        "symbol_pool_pbo": pbo,
        "pbo_pass": pbo_pass,
        "core_edge_survivors": len(core_survivors),
        "core_plus_risk_v2_survivors": len(risk_survivors),
        "phase3_v2_survivors": len(survivors),
        "phase3_v2_sub1r_survivors": sum(1 for row in survivors if row["rr"] < 1.0),
        "top_survivors": survivors[:25],
        "notes": [
            "V2 removes the fixed 8R hard-ruin gate from confirmatory approval.",
            "Ruin is evaluated as capital drawdown under explicit risk-per-1R profiles.",
            "Moving-block bootstrap preserves local trade dependence better than IID resampling.",
            "DSR is reported against the 165 frozen survivor pool and against an upper-bound full-search trial count.",
            "CSCV-style PBO is estimated across chronological quarter blocks for the frozen candidate pool of each symbol.",
            "The 2020-01-02/2022-08-31 holdout is not queried or used here.",
            "Live money remains disabled.",
        ],
    }
    (out / "phase3_risk_gate_v2_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    (out / "phase3_risk_gate_v2_all_candidates.json").write_text(
        json.dumps(results, indent=2), encoding="utf-8"
    )
    (out / "phase3_risk_gate_v2_survivors.json").write_text(
        json.dumps(survivors, indent=2), encoding="utf-8"
    )

    print("PHASE3_RISK_GATE_V2_OK", flush=True)
    print(
        json.dumps(
            {
                "symbol": symbol,
                "frozen_candidates": len(frozen),
                "core_edge_survivors": len(core_survivors),
                "core_plus_risk_v2_survivors": len(risk_survivors),
                "phase3_v2_survivors": len(survivors),
                "pbo": pbo,
            },
            indent=2,
        ),
        flush=True,
    )


if __name__ == "__main__":
    main()
