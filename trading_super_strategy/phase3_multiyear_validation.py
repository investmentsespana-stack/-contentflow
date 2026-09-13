import json
import math
import os
from datetime import date, datetime
from pathlib import Path

import databento as db
import pandas as pd

import real_strategy_discovery as base
from coalition_backtester import CoalitionBacktester, ContextKey
from phase2_historical_search import fast_build_events
from robustness_engine import MonteCarloConfig, MonteCarloRobustnessEngine, max_drawdown_r


SOURCE_RUNS = {"60": 34759467675, "126": 34759985485, "250": 34761821904}
VALIDATION_START = os.getenv("PHASE3_START_DATE", "2022-09-01")
VALIDATION_END = os.getenv("PHASE3_END_DATE", "2025-09-24")
BASELINE_COST_R = float(os.getenv("PHASE3_COST_R", "0.03"))
MC_ITERATIONS = int(os.getenv("PHASE3_MC_ITERATIONS", "2000"))
MIN_FULL_TRADES = int(os.getenv("PHASE3_MIN_TRADES", "60"))
MIN_FOLD_TRADES = int(os.getenv("PHASE3_MIN_FOLD_TRADES", "5"))
MIN_ELIGIBLE_FOLDS = int(os.getenv("PHASE3_MIN_FOLDS", "3"))
MIN_POSITIVE_FOLD_RATE = float(os.getenv("PHASE3_MIN_POSITIVE_FOLD_RATE", "0.60"))


def fingerprint(row):
    c = row["context"]
    oos = row["oos"]
    return (
        row["symbol"],
        float(row["rr"]),
        oos["direction"],
        tuple(oos["members"]),
        c["session"],
        c["minutes_from_open_bucket"],
        c["volatility_regime"],
        c["trend_regime"],
        c["structure_regime"],
    )


def load_phase2_rows(horizon, symbol):
    path = (
        Path("phase3_inputs")
        / horizon
        / f"trading-phase2-{symbol}"
        / "phase2_all_coalitions.json"
    )
    if not path.exists():
        raise SystemExit(f"Missing Phase 2 artifact: {path}")
    rows = json.loads(path.read_text(encoding="utf-8"))
    return [row for row in rows if row["symbol"] == symbol]


def freeze_exact_intersection(symbol):
    maps = {}
    for horizon in SOURCE_RUNS:
        rows = load_phase2_rows(horizon, symbol)
        maps[horizon] = {fingerprint(row): row for row in rows}

    keys = set(maps["60"]) & set(maps["126"]) & set(maps["250"])
    frozen = []
    for key in sorted(keys):
        row = maps["250"][key]
        frozen.append(
            {
                "symbol": row["symbol"],
                "rr": float(row["rr"]),
                "direction": row["oos"]["direction"],
                "members": list(row["oos"]["members"]),
                "context": dict(row["context"]),
            }
        )
    return frozen


def pf(returns_r):
    gp = sum(x for x in returns_r if x > 0)
    gl = abs(sum(x for x in returns_r if x < 0))
    if gl > 0:
        return gp / gl
    return float("inf") if gp > 0 else 0.0


def metrics(returns_r):
    n = len(returns_r)
    wins = sum(1 for x in returns_r if x > 0)
    return {
        "trades": n,
        "wins": wins,
        "win_rate": wins / n if n else 0.0,
        "expectancy_r": sum(returns_r) / n if n else 0.0,
        "profit_factor": pf(returns_r),
        "max_drawdown_r": max_drawdown_r(returns_r),
        "total_r": sum(returns_r),
    }


def context_from_candidate(candidate):
    c = candidate["context"]
    return ContextKey(
        instrument=candidate["symbol"],
        session=c["session"],
        minutes_from_open_bucket=c["minutes_from_open_bucket"],
        volatility_regime=c["volatility_regime"],
        trend_regime=c["trend_regime"],
        structure_regime=c["structure_regime"],
    )


def direction_value(text):
    if text == "LONG":
        return 1
    if text == "SHORT":
        return -1
    raise ValueError(f"Unsupported direction: {text}")


def candidate_key(candidate):
    c = candidate["context"]
    return "|".join(
        [
            candidate["symbol"],
            str(candidate["rr"]),
            candidate["direction"],
            "+".join(candidate["members"]),
            c["session"],
            c["minutes_from_open_bucket"],
            c["volatility_regime"],
            c["trend_regime"],
            c["structure_regime"],
        ]
    )


def main():
    api_key = os.getenv("DATABENTO_API_KEY", "")
    if not api_key:
        raise SystemExit("DATABENTO_API_KEY secret is missing")

    symbol = os.getenv("PHASE3_SYMBOL", "").strip()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported PHASE3_SYMBOL: {symbol}")

    frozen = freeze_exact_intersection(symbol)
    if not frozen:
        raise SystemExit(f"No frozen Phase 2 survivors for {symbol}")

    print(
        f"PHASE3_FROZEN symbol={symbol} candidates={len(frozen)} "
        f"sub1r={sum(1 for x in frozen if x['rr'] < 1.0)}",
        flush=True,
    )

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
        raise SystemExit("No Databento rows returned for Phase 3")

    idx = pd.DatetimeIndex(df.index)
    if idx.tz is None:
        idx = idx.tz_localize("UTC")
    work = df.copy()
    work["local_time"] = idx.tz_convert(base.TZ)
    work = work.sort_values("local_time")
    work = work[~work.index.duplicated(keep="first")].copy()
    enriched = base.enrich_symbol(work)

    years = sorted(int(y) for y in enriched["local_time"].dt.year.unique())
    rrs = sorted({float(row["rr"]) for row in frozen})
    backtester = CoalitionBacktester()
    mc_engine = MonteCarloRobustnessEngine()

    full_events = {}
    fold_events = {}
    for rr in rrs:
        full_events[rr] = fast_build_events(enriched, symbol, rr, BASELINE_COST_R)
        fold_events[rr] = {}
        for year in years:
            fold_frame = enriched[enriched["local_time"].dt.year == year].copy()
            fold_events[rr][year] = fast_build_events(
                fold_frame, symbol, rr, BASELINE_COST_R
            )
        print(
            f"PHASE3_DATA symbol={symbol} rr={rr} events={len(full_events[rr])}",
            flush=True,
        )

    results = []
    survivors = []
    for index, candidate in enumerate(frozen, start=1):
        rr = float(candidate["rr"])
        direction = direction_value(candidate["direction"])
        context = context_from_candidate(candidate)
        members = candidate["members"]

        returns_r = backtester.returns_for(
            full_events[rr], members, direction, context=context
        )
        base_metrics = metrics(returns_r)
        stressed_15 = [x - BASELINE_COST_R * 0.5 for x in returns_r]
        stressed_20 = [x - BASELINE_COST_R for x in returns_r]

        folds = []
        eligible_fold_returns = []
        for year in years:
            fold_returns = backtester.returns_for(
                fold_events[rr][year], members, direction, context=context
            )
            fold_metric = metrics(fold_returns)
            fold_metric["year"] = year
            fold_metric["eligible"] = len(fold_returns) >= MIN_FOLD_TRADES
            folds.append(fold_metric)
            if fold_metric["eligible"]:
                eligible_fold_returns.append(fold_metric)

        positive_folds = sum(
            1 for fold in eligible_fold_returns if fold["expectancy_r"] > 0
        )
        positive_fold_rate = (
            positive_folds / len(eligible_fold_returns)
            if eligible_fold_returns
            else 0.0
        )

        mc_payload = None
        if returns_r:
            mc = mc_engine.run(
                returns_r,
                MonteCarloConfig(
                    iterations=MC_ITERATIONS,
                    seed=31,
                    omit_trade_probability=0.05,
                    extra_cost_r=BASELINE_COST_R * 0.5,
                    slippage_r_std=0.03,
                    ruin_drawdown_r=8.0,
                ),
            )
            mc_payload = {
                "iterations": mc.iterations,
                "profitable_probability": mc.profitable_probability,
                "ruin_probability": mc.ruin_probability,
                "median_total_r": mc.median_total_r,
                "p05_total_r": mc.p05_total_r,
                "median_max_drawdown_r": mc.median_max_drawdown_r,
                "p95_max_drawdown_r": mc.p95_max_drawdown_r,
                "median_win_rate": mc.median_win_rate,
            }

        fail_reasons = []
        if base_metrics["trades"] < MIN_FULL_TRADES:
            fail_reasons.append("insufficient_full_trades")
        if base_metrics["expectancy_r"] <= 0:
            fail_reasons.append("nonpositive_baseline_expectancy")
        if base_metrics["profit_factor"] <= 1.05:
            fail_reasons.append("profit_factor_le_1_05")
        if metrics(stressed_20)["expectancy_r"] <= 0:
            fail_reasons.append("fails_2x_cost_stress")
        if len(eligible_fold_returns) < MIN_ELIGIBLE_FOLDS:
            fail_reasons.append("insufficient_time_folds")
        if positive_fold_rate < MIN_POSITIVE_FOLD_RATE:
            fail_reasons.append("unstable_time_folds")
        if mc_payload is None or mc_payload["p05_total_r"] <= 0:
            fail_reasons.append("mc_p05_nonpositive")
        if mc_payload is None or mc_payload["ruin_probability"] > 0.01:
            fail_reasons.append("mc_ruin_gt_1pct")

        result = {
            **candidate,
            "candidate_key": candidate_key(candidate),
            "validation_period": {
                "start": VALIDATION_START,
                "end": VALIDATION_END,
            },
            "baseline": base_metrics,
            "cost_stress_1_5x": metrics(stressed_15),
            "cost_stress_2x": metrics(stressed_20),
            "time_folds": folds,
            "eligible_folds": len(eligible_fold_returns),
            "positive_fold_rate": positive_fold_rate,
            "monte_carlo": mc_payload,
            "phase3_pass": not fail_reasons,
            "fail_reasons": fail_reasons,
        }
        results.append(result)
        if result["phase3_pass"]:
            survivors.append(result)

        if index % 10 == 0 or index == len(frozen):
            print(
                f"PHASE3_PROGRESS symbol={symbol} tested={index}/{len(frozen)} "
                f"passed={len(survivors)}",
                flush=True,
            )

    survivors.sort(
        key=lambda row: (
            row["monte_carlo"]["p05_total_r"],
            row["baseline"]["expectancy_r"],
            row["positive_fold_rate"],
            -row["baseline"]["max_drawdown_r"],
        ),
        reverse=True,
    )

    out = Path("phase3_multiyear_output")
    out.mkdir(exist_ok=True)
    summary = {
        "phase": "3_MULTIYEAR_CONFIRMATORY_VALIDATION",
        "symbol": symbol,
        "source_phase2_runs": SOURCE_RUNS,
        "frozen_candidates": len(frozen),
        "frozen_sub1r": sum(1 for x in frozen if x["rr"] < 1.0),
        "validation_start": VALIDATION_START,
        "validation_end": VALIDATION_END,
        "reserved_untouched_holdout": "2020-01-02/2022-08-31",
        "rows_downloaded": len(enriched),
        "calendar_year_folds": years,
        "baseline_cost_r": BASELINE_COST_R,
        "cost_stress_multipliers": [1.0, 1.5, 2.0],
        "monte_carlo_iterations": MC_ITERATIONS,
        "phase3_survivors": len(survivors),
        "phase3_sub1r_survivors": sum(
            1 for row in survivors if float(row["rr"]) < 1.0
        ),
        "top_survivors": survivors[:25],
        "research_notes": [
            "Confirmatory only: no new coalition/member/context/RR search in Phase 3.",
            "Candidates were frozen as the exact 60/126/250-session intersection before validation.",
            "Validation data predates the discovery period.",
            "2020-01-02 through 2022-08-31 remains untouched as a later final holdout.",
            "Pass requires positive baseline edge, 2x cost-stress edge, time-fold stability, and positive Monte Carlo P05.",
            "Live money remains disabled.",
        ],
    }
    (out / "phase3_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    (out / "phase3_all_candidates.json").write_text(
        json.dumps(results, indent=2), encoding="utf-8"
    )
    (out / "phase3_survivors.json").write_text(
        json.dumps(survivors, indent=2), encoding="utf-8"
    )

    print("PHASE3_MULTIYEAR_VALIDATION_OK", flush=True)
    print(json.dumps({
        "symbol": symbol,
        "frozen_candidates": len(frozen),
        "rows_downloaded": len(enriched),
        "survivors": len(survivors),
        "sub1r_survivors": summary["phase3_sub1r_survivors"],
    }, indent=2), flush=True)


if __name__ == "__main__":
    main()
