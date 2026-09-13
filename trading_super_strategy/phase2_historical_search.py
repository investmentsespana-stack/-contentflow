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


def _trade_outcome_arrays(open_, high, low, close, atr, pos, direction, rr, horizon=30):
    if pos + 1 >= len(open_):
        return None
    risk = float(atr[pos])
    if not math.isfinite(risk) or risk <= 0:
        return None
    entry = float(open_[pos + 1])
    target = entry + direction * rr * risk
    stop = entry - direction * risk
    last = min(len(open_) - 1, pos + horizon)

    for j in range(pos + 1, last + 1):
        h = float(high[j])
        l = float(low[j])
        if direction == 1:
            target_hit = h >= target
            stop_hit = l <= stop
        else:
            target_hit = l <= target
            stop_hit = h >= stop
        # Conservative ambiguity rule: if both are reachable in one 1m bar,
        # the stop is counted first until finer data can resolve ordering.
        if stop_hit:
            return -1.0
        if target_hit:
            return rr

    return direction * (float(close[last]) - entry) / risk


def fast_build_events(g, symbol, rr, cost_r):
    """Build events without repeated pandas .iloc access inside the hot loop."""
    records = g.reset_index(drop=True)
    open_ = records["open"].to_numpy()
    high = records["high"].to_numpy()
    low = records["low"].to_numpy()
    close = records["close"].to_numpy()
    atr = records["atr14"].to_numpy()
    sma40 = records["sma40"].to_numpy()
    local_time = records["local_time"].tolist()
    vol_regime = records["vol_regime"].astype(str).to_numpy()
    trend_regime = records["trend_regime"].astype(str).to_numpy()
    structure_regime = records["structure_regime"].astype(str).to_numpy()
    signal_arrays = {
        name: records[f"sig_{name}"].fillna(0).astype(int).to_numpy()
        for name in base.STRATEGIES
    }

    events = []
    for pos in range(len(records) - 1):
        if not math.isfinite(float(atr[pos])) or not math.isfinite(float(sma40[pos])):
            continue
        if not any(signal_arrays[name][pos] != 0 for name in base.STRATEGIES):
            continue

        long_r = _trade_outcome_arrays(open_, high, low, close, atr, pos, 1, rr)
        short_r = _trade_outcome_arrays(open_, high, low, close, atr, pos, -1, rr)
        if long_r is None or short_r is None:
            continue

        ts = local_time[pos]
        context = base.ContextKey(
            instrument=str(symbol),
            session=base.session_label(ts),
            minutes_from_open_bucket=base.open_bucket(ts),
            volatility_regime=str(vol_regime[pos]),
            trend_regime=str(trend_regime[pos]),
            structure_regime=str(structure_regime[pos]),
        )
        signals = {name: int(signal_arrays[name][pos]) for name in base.STRATEGIES}
        events.append(
            base.BacktestEvent(
                context=context,
                signals=signals,
                coordinated_long_return_r=float(long_r),
                coordinated_short_return_r=float(short_r),
                execution_cost_r=cost_r,
            )
        )
    return events


def write_progress(out, payload, all_results, search_ledger):
    with open(out / "phase2_progress.json", "w", encoding="utf-8") as f:
        json.dump(payload, f, indent=2)
    with open(out / "phase2_all_coalitions.partial.json", "w", encoding="utf-8") as f:
        json.dump(all_results, f, indent=2)
    with open(out / "phase2_trial_ledger.partial.json", "w", encoding="utf-8") as f:
        json.dump(search_ledger, f, indent=2)


def main():
    key = os.getenv("DATABENTO_API_KEY", "")
    if not key:
        raise SystemExit("DATABENTO_API_KEY secret is missing")

    session_count = int(os.getenv("PHASE2_SESSIONS", "60"))
    cost_r = float(os.getenv("PHASE2_COST_R", "0.03"))
    end_text = os.getenv("PHASE2_END_DATE", "2026-09-11")
    end = datetime.fromisoformat(end_text).replace(tzinfo=base.TZ)
    dates = base.weekdays(end, session_count)
    date_strings = {str(d) for d in dates}

    symbol_text = os.getenv("PHASE2_SYMBOLS", "").strip()
    selected_symbols = [s.strip() for s in symbol_text.split(",") if s.strip()] or list(base.SYMBOLS)
    unknown = [s for s in selected_symbols if s not in base.SYMBOLS]
    if unknown:
        raise SystemExit(f"Unsupported PHASE2_SYMBOLS: {unknown}")

    client = db.Historical(key)
    out = Path("phase2_historical_output")
    out.mkdir(exist_ok=True)

    # Root-cause repair: one contiguous Databento request per shard instead of
    # one API request per session. Bars are then mapped back to futures sessions.
    earliest_start = dates[0] - timedelta(days=1)
    data = client.timeseries.get_range(
        dataset="GLBX.MDP3",
        schema="ohlcv-1m",
        stype_in="continuous",
        symbols=selected_symbols,
        start=base.utc_iso(earliest_start, 18, 0),
        end=base.utc_iso(dates[-1], 16, 0),
    )
    df = data.to_df()
    if df.empty:
        raise SystemExit("No Databento rows returned")

    idx = pd.DatetimeIndex(df.index)
    if idx.tz is None:
        idx = idx.tz_localize("UTC")
    work = df.copy()
    work["local_time"] = idx.tz_convert(base.TZ)
    normalized = work["local_time"].dt.normalize()
    normalized = normalized + pd.to_timedelta((work["local_time"].dt.hour >= 18).astype(int), unit="D")
    work["target_session_date"] = normalized.dt.date.astype(str)
    work = work[work["target_session_date"].isin(date_strings)].copy()

    if work.empty:
        raise SystemExit("Databento returned no rows for requested completed sessions")

    rows_downloaded = len(work)
    completed_sessions = sorted(work["target_session_date"].unique().tolist())
    by_symbol_frames = {str(symbol): g.copy() for symbol, g in work.groupby("symbol")}
    print(
        f"PHASE2_DATA_READY symbols={selected_symbols} sessions={len(completed_sessions)} rows={rows_downloaded}",
        flush=True,
    )

    backtester = CoalitionBacktester()
    mc_engine = MonteCarloRobustnessEngine()
    all_results = []
    signal_counts = {}
    search_ledger = []
    total_trials = 0
    trials_per_context = combo_count(len(base.STRATEGIES))
    processed_rr = []

    for symbol, frame in by_symbol_frames.items():
        g = frame.sort_values("local_time")
        g = g[~g.index.duplicated(keep="first")].copy()
        g = base.enrich_symbol(g)
        signal_counts[symbol] = {
            name: int((g[f"sig_{name}"] != 0).sum()) for name in base.STRATEGIES
        }

        for rr in RR_CANDIDATES:
            events = fast_build_events(g, symbol, rr, cost_r)
            grouped = defaultdict(list)
            for event in events:
                if event.context.trend_regime not in {"bullish", "bearish"}:
                    continue
                grouped[event.context].append(event)

            rr_survivors_before = len(all_results)
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

                search_ledger.append({
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
                })

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

            processed_rr.append({"symbol": symbol, "rr": rr})
            progress = {
                "status": "running",
                "sessions_requested": session_count,
                "sessions_completed": len(completed_sessions),
                "symbols": selected_symbols,
                "processed_rr": processed_rr,
                "rows_downloaded": rows_downloaded,
                "total_coalition_trials": total_trials,
                "surviving_directional_coalitions": len(all_results),
                "new_survivors_this_rr": len(all_results) - rr_survivors_before,
            }
            write_progress(out, progress, all_results, search_ledger)
            print(
                f"PHASE2_PROGRESS symbol={symbol} rr={rr} trials={total_trials} survivors={len(all_results)}",
                flush=True,
            )

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
        "symbols": selected_symbols,
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

    write_progress(
        out,
        {
            "status": "completed",
            "sessions_requested": session_count,
            "sessions_completed": len(completed_sessions),
            "symbols": selected_symbols,
            "processed_rr": processed_rr,
            "rows_downloaded": rows_downloaded,
            "total_coalition_trials": total_trials,
            "surviving_directional_coalitions": len(all_results),
        },
        all_results,
        search_ledger,
    )

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
