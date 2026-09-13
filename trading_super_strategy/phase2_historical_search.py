import json
import math
import os
from collections import defaultdict
from datetime import datetime, timedelta
from pathlib import Path

import databento as db
import pandas as pd

import real_strategy_discovery as base
from coalition_backtester import CoalitionBacktester
from robustness_engine import MonteCarloConfig, MonteCarloRobustnessEngine

RR_CANDIDATES = [0.25, 0.40, 0.50, 0.70, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0]
MEMBER_SIZES = (2, 3, 4)
TRAIN_FRACTION = 0.70
MIN_CONTEXT_EVENTS = 150
MIN_TRAIN_TRADES = 40
MIN_OOS_TRADES = 20
TOP_N_TRAIN = 50
MC_ITERATIONS = 2000


def combo_count(n_strategies: int) -> int:
    return sum(math.comb(n_strategies, size) for size in MEMBER_SIZES)


def main():
    key = os.getenv("DATABENTO_API_KEY", "")
    if not key:
        raise SystemExit("DATABENTO_API_KEY secret is missing")

    session_count = int(os.getenv("PHASE2_SESSIONS", "60"))
    cost_r = float(os.getenv("PHASE2_COST_R", "0.03"))
    end_text = os.getenv("PHASE2_END_DATE", "2026-09-11")
    end = datetime.fromisoformat(end_text).replace(tzinfo=base.TZ)
    dates = base.weekdays(end, session_count)
    client = db.Historical(key)

    out = Path("phase2_historical_output")
    out.mkdir(exist_ok=True)

    by_symbol_frames = defaultdict(list)
    rows_downloaded = 0
    completed_sessions = []

    for d in dates:
        start_date = d - timedelta(days=1)
        data = client.timeseries.get_range(
            dataset="GLBX.MDP3",
            schema="ohlcv-1m",
            stype_in="continuous",
            symbols=base.SYMBOLS,
            start=base.utc_iso(start_date, 18, 0),
            end=base.utc_iso(d, 16, 0),
        )
        df = data.to_df()
        if df.empty:
            continue
        idx = pd.DatetimeIndex(df.index)
        if idx.tz is None:
            idx = idx.tz_localize("UTC")
        work = df.copy()
        work["local_time"] = idx.tz_convert(base.TZ)
        work["target_session_date"] = str(d)
        rows_downloaded += len(work)
        completed_sessions.append(str(d))
        for symbol, g in work.groupby("symbol"):
            by_symbol_frames[str(symbol)].append(g.copy())

    if not by_symbol_frames:
        raise SystemExit("No Databento rows returned")

    backtester = CoalitionBacktester()
    mc_engine = MonteCarloRobustnessEngine()
    all_results = []
    signal_counts = {}
    search_ledger = []
    total_trials = 0
    trials_per_context = combo_count(len(base.STRATEGIES))

    for symbol, frames in by_symbol_frames.items():
        g = pd.concat(frames).sort_values("local_time")
        g = g[~g.index.duplicated(keep="first")].copy()
        g = base.enrich_symbol(g)
        signal_counts[symbol] = {
            name: int((g[f"sig_{name}"] != 0).sum()) for name in base.STRATEGIES
        }

        for rr in RR_CANDIDATES:
            events = base.build_events(g, symbol, rr, cost_r)
            grouped = defaultdict(list)
            for event in events:
                if event.context.trend_regime not in {"bullish", "bearish"}:
                    continue
                grouped[event.context].append(event)

            for context, context_events in grouped.items():
                if len(context_events) < MIN_CONTEXT_EVENTS:
                    continue

                direction = 1 if context.trend_regime == "bullish" else -1
                total_trials += trials_per_context
                survivors = backtester.train_oos_search(
                    context_events,
                    base.STRATEGIES,
                    direction,
                    train_fraction=TRAIN_FRACTION,
                    member_sizes=MEMBER_SIZES,
                    min_train_trades=MIN_TRAIN_TRADES,
                    min_oos_trades=MIN_OOS_TRADES,
                    top_n_train=TOP_N_TRAIN,
                )

                ledger_row = {
                    "symbol": symbol,
                    "rr": rr,
                    "session": context.session,
                    "minutes_from_open_bucket": context.minutes_from_open_bucket,
                    "volatility_regime": context.volatility_regime,
                    "trend_regime": context.trend_regime,
                    "structure_regime": context.structure_regime,
                    "direction": "LONG" if direction == 1 else "SHORT",
                    "context_events": len(context_events),
                    "coalitions_tested": trials_per_context,
                    "oos_survivors": len(survivors),
                }
                search_ledger.append(ledger_row)

                if not survivors:
                    continue

                split = max(1, min(len(context_events) - 1, int(len(context_events) * TRAIN_FRACTION)))
                oos_events = context_events[split:]
                for train_metrics, oos_metrics in survivors[:5]:
                    oos_returns = backtester.returns_for(oos_events, oos_metrics.members, direction)
                    if len(oos_returns) < MIN_OOS_TRADES:
                        continue
                    mc = mc_engine.run(
                        oos_returns,
                        MonteCarloConfig(
                            iterations=MC_ITERATIONS,
                            seed=23,
                            omit_trade_probability=0.05,
                            extra_cost_r=0.015,
                            slippage_r_std=0.03,
                            ruin_drawdown_r=8.0,
                        ),
                    )
                    all_results.append({
                        "symbol": symbol,
                        "rr": rr,
                        "context": {
                            "session": context.session,
                            "minutes_from_open_bucket": context.minutes_from_open_bucket,
                            "volatility_regime": context.volatility_regime,
                            "trend_regime": context.trend_regime,
                            "structure_regime": context.structure_regime,
                        },
                        "train": base.serialize_metrics(train_metrics),
                        "oos": base.serialize_metrics(oos_metrics),
                        "monte_carlo_oos": {
                            "iterations": mc.iterations,
                            "profitable_probability": mc.profitable_probability,
                            "ruin_probability": mc.ruin_probability,
                            "median_total_r": mc.median_total_r,
                            "p05_total_r": mc.p05_total_r,
                            "median_max_drawdown_r": mc.median_max_drawdown_r,
                            "p95_max_drawdown_r": mc.p95_max_drawdown_r,
                            "median_win_rate": mc.median_win_rate,
                        },
                    })

    all_results.sort(key=lambda row: (
        row["monte_carlo_oos"]["ruin_probability"],
        -row["oos"]["expectancy_r"],
        -row["oos"]["win_rate"],
        row["oos"]["max_drawdown_r"],
    ))

    summary = {
        "phase": "2A_EXPANDED_HISTORICAL_SEARCH",
        "sessions_requested": session_count,
        "sessions_completed": len(completed_sessions),
        "date_start": completed_sessions[0] if completed_sessions else None,
        "date_end": completed_sessions[-1] if completed_sessions else None,
        "rows_downloaded": rows_downloaded,
        "symbols": base.SYMBOLS,
        "strategies": base.STRATEGIES,
        "rr_candidates": RR_CANDIDATES,
        "sub_1r_candidates": [x for x in RR_CANDIDATES if x < 1.0],
        "execution_cost_r_assumption": cost_r,
        "train_fraction": TRAIN_FRACTION,
        "min_context_events": MIN_CONTEXT_EVENTS,
        "min_train_trades": MIN_TRAIN_TRADES,
        "min_oos_trades": MIN_OOS_TRADES,
        "member_sizes": list(MEMBER_SIZES),
        "trials_per_context": trials_per_context,
        "total_coalition_trials": total_trials,
        "surviving_directional_coalitions": len(all_results),
        "signal_counts": signal_counts,
        "top_results": all_results[:50],
        "research_notes": [
            "Phase 2A broad search on real Databento OHLCV-1m.",
            "LONG and SHORT are evaluated independently; sideways remains NO_TRADE.",
            "Sub-1R candidates are explicit search variables and are not privileged by win rate.",
            "Ranking emphasizes OOS expectancy and Monte Carlo survival before win rate.",
            "Signals are evaluated at bar close with next-bar entry.",
            "Same-bar target/stop ambiguity is resolved conservatively as stop-first.",
            "No candidate is eligible for paper/live until walk-forward, PBO/DSR, cost stress and larger holdout validation complete.",
            "Live money remains disabled."
        ],
    }

    with open(out / "phase2_summary.json", "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    with open(out / "phase2_all_coalitions.json", "w", encoding="utf-8") as f:
        json.dump(all_results, f, indent=2)
    with open(out / "phase2_trial_ledger.json", "w", encoding="utf-8") as f:
        json.dump(search_ledger, f, indent=2)

    print("PHASE2_HISTORICAL_SEARCH_OK")
    print(json.dumps({
        "sessions_completed": len(completed_sessions),
        "rows_downloaded": rows_downloaded,
        "total_coalition_trials": total_trials,
        "surviving_directional_coalitions": len(all_results),
        "top_results": all_results[:5],
    }, indent=2))


if __name__ == "__main__":
    main()
