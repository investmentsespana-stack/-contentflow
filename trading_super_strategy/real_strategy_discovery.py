import json
import os
from collections import defaultdict
from datetime import datetime, time, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import databento as db
import pandas as pd

from coalition_backtester import BacktestEvent, CoalitionBacktester, ContextKey
from robustness_engine import MonteCarloConfig, MonteCarloRobustnessEngine


TZ = ZoneInfo("America/New_York")
UTC = ZoneInfo("UTC")
SYMBOLS = ["NQ.v.0", "ES.v.0", "YM.v.0", "RTY.v.0"]
STRATEGIES = [
    "breakout20",
    "momentum10",
    "meanrev_z20",
    "vwap_reversion",
    "rsi14_reversion",
    "liquidity_sweep20",
    "trend_pullback",
    "volume_breakout",
]
RR_CANDIDATES = [0.5, 0.75, 1.0, 1.5, 2.0]


def weekdays(end_date: datetime, count: int):
    out = []
    d = end_date.date()
    while len(out) < count:
        if d.weekday() < 5:
            out.append(d)
        d -= timedelta(days=1)
    return sorted(out)


def utc_iso(d, hh, mm=0):
    local = datetime.combine(d, time(hh, mm), TZ)
    return local.astimezone(UTC).isoformat().replace("+00:00", "Z")


def session_label(ts):
    t = ts.time()
    if t >= time(18, 0):
        return "globex_evening"
    if t < time(2, 0):
        return "overnight_early"
    if t < time(8, 0):
        return "europe_proxy"
    if t < time(9, 30):
        return "pre_ny_cash"
    if t < time(11, 0):
        return "ny_open_0_90"
    if t < time(14, 0):
        return "ny_midday"
    if t < time(16, 0):
        return "ny_afternoon"
    return "globex_transition"


def open_bucket(ts):
    anchor = ts.replace(hour=9, minute=30, second=0, microsecond=0)
    minutes = int((ts - anchor).total_seconds() // 60)
    if minutes < -450:
        return "pre_lt_-450"
    if minutes < -90:
        return "pre_-450_-90"
    if minutes < 0:
        return "pre_-90_0"
    if minutes < 30:
        return "open_0_30"
    if minutes < 90:
        return "open_30_90"
    if minutes < 270:
        return "post_90_270"
    return "post_270_plus"


def rsi(close, length=14):
    delta = close.diff()
    gain = delta.clip(lower=0.0).rolling(length).mean()
    loss = (-delta.clip(upper=0.0)).rolling(length).mean()
    rs = gain / loss.replace(0.0, float("nan"))
    return 100.0 - (100.0 / (1.0 + rs))


def enrich_symbol(g):
    g = g.sort_values("local_time").copy()
    prev_close = g["close"].shift(1)
    tr = pd.concat(
        [
            g["high"] - g["low"],
            (g["high"] - prev_close).abs(),
            (g["low"] - prev_close).abs(),
        ],
        axis=1,
    ).max(axis=1)
    g["tr"] = tr
    g["atr14"] = tr.rolling(14).mean()
    g["atr60_med"] = g["atr14"].rolling(60).median()
    g["sma10"] = g["close"].rolling(10).mean()
    g["sma20"] = g["close"].rolling(20).mean()
    g["sma40"] = g["close"].rolling(40).mean()
    g["std20"] = g["close"].rolling(20).std()
    g["prev_high20"] = g["high"].rolling(20).max().shift(1)
    g["prev_low20"] = g["low"].rolling(20).min().shift(1)
    g["volume20"] = g["volume"].rolling(20).mean().shift(1)
    g["rsi14"] = rsi(g["close"], 14)
    g["momentum10_z"] = (g["close"] - g["close"].shift(10)) / g["atr14"].replace(0.0, float("nan"))
    g["z20"] = (g["close"] - g["sma20"]) / g["std20"].replace(0.0, float("nan"))

    # Session VWAP proxy resets by ET calendar date. This is a research feature,
    # not an exchange session accounting definition.
    local_date = g["local_time"].dt.date
    typical = (g["high"] + g["low"] + g["close"]) / 3.0
    pv = typical * g["volume"]
    g["vwap"] = pv.groupby(local_date).cumsum() / g["volume"].groupby(local_date).cumsum().replace(0, float("nan"))
    g["vwap_z"] = (g["close"] - g["vwap"]) / g["atr14"].replace(0.0, float("nan"))

    vol_ratio = g["atr14"] / g["atr60_med"].replace(0.0, float("nan"))
    g["vol_regime"] = "medium"
    g.loc[vol_ratio < 0.80, "vol_regime"] = "low"
    g.loc[vol_ratio > 1.20, "vol_regime"] = "high"

    trend_distance = (g["sma10"] - g["sma40"]).abs()
    g["trend_regime"] = "sideways"
    g.loc[(g["sma10"] > g["sma40"]) & (trend_distance > 0.25 * g["atr14"]), "trend_regime"] = "bullish"
    g.loc[(g["sma10"] < g["sma40"]) & (trend_distance > 0.25 * g["atr14"]), "trend_regime"] = "bearish"

    tr_med20 = g["tr"].rolling(20).median()
    g["structure_regime"] = "normal"
    g.loc[g["tr"] > 1.5 * tr_med20, "structure_regime"] = "expansion"
    g.loc[g["tr"] < 0.70 * tr_med20, "structure_regime"] = "compression"

    signals = pd.DataFrame(index=g.index)
    signals["breakout20"] = 0
    signals.loc[g["close"] > g["prev_high20"], "breakout20"] = 1
    signals.loc[g["close"] < g["prev_low20"], "breakout20"] = -1

    signals["momentum10"] = 0
    signals.loc[g["momentum10_z"] > 1.25, "momentum10"] = 1
    signals.loc[g["momentum10_z"] < -1.25, "momentum10"] = -1

    signals["meanrev_z20"] = 0
    signals.loc[g["z20"] < -1.5, "meanrev_z20"] = 1
    signals.loc[g["z20"] > 1.5, "meanrev_z20"] = -1

    signals["vwap_reversion"] = 0
    signals.loc[g["vwap_z"] < -1.25, "vwap_reversion"] = 1
    signals.loc[g["vwap_z"] > 1.25, "vwap_reversion"] = -1

    signals["rsi14_reversion"] = 0
    signals.loc[g["rsi14"] < 30, "rsi14_reversion"] = 1
    signals.loc[g["rsi14"] > 70, "rsi14_reversion"] = -1

    signals["liquidity_sweep20"] = 0
    long_sweep = (g["low"] < g["prev_low20"]) & (g["close"] > g["prev_low20"])
    short_sweep = (g["high"] > g["prev_high20"]) & (g["close"] < g["prev_high20"])
    signals.loc[long_sweep, "liquidity_sweep20"] = 1
    signals.loc[short_sweep, "liquidity_sweep20"] = -1

    signals["trend_pullback"] = 0
    long_pullback = (g["sma10"] > g["sma40"]) & (g["close"] < g["sma10"]) & (g["close"] > g["sma40"])
    short_pullback = (g["sma10"] < g["sma40"]) & (g["close"] > g["sma10"]) & (g["close"] < g["sma40"])
    signals.loc[long_pullback, "trend_pullback"] = 1
    signals.loc[short_pullback, "trend_pullback"] = -1

    signals["volume_breakout"] = 0
    volume_expanded = g["volume"] > 1.5 * g["volume20"]
    signals.loc[volume_expanded & (g["close"] > g["prev_high20"]), "volume_breakout"] = 1
    signals.loc[volume_expanded & (g["close"] < g["prev_low20"]), "volume_breakout"] = -1

    for name in STRATEGIES:
        g[f"sig_{name}"] = signals[name].fillna(0).astype(int)
    return g


def trade_outcome(g, pos, direction, rr, horizon=30):
    if pos + 1 >= len(g):
        return None
    atr = float(g.iloc[pos]["atr14"])
    if not atr or pd.isna(atr) or atr <= 0:
        return None
    entry = float(g.iloc[pos + 1]["open"])
    target = entry + direction * rr * atr
    stop = entry - direction * atr
    last = min(len(g) - 1, pos + horizon)

    for j in range(pos + 1, last + 1):
        high = float(g.iloc[j]["high"])
        low = float(g.iloc[j]["low"])
        if direction == 1:
            target_hit = high >= target
            stop_hit = low <= stop
        else:
            target_hit = low <= target
            stop_hit = high >= stop
        # Conservative OHLC ambiguity rule: if both could occur in one bar,
        # count the stop first until trade/tick data can resolve ordering.
        if stop_hit:
            return -1.0
        if target_hit:
            return rr

    exit_price = float(g.iloc[last]["close"])
    return direction * (exit_price - entry) / atr


def build_events(g, symbol, rr, cost_r):
    events = []
    records = g.reset_index(drop=True)
    for pos in range(len(records) - 1):
        row = records.iloc[pos]
        if pd.isna(row["atr14"]) or pd.isna(row["sma40"]):
            continue
        if not any(int(row[f"sig_{name}"]) != 0 for name in STRATEGIES):
            continue
        ts = row["local_time"]
        context = ContextKey(
            instrument=str(symbol),
            session=session_label(ts),
            minutes_from_open_bucket=open_bucket(ts),
            volatility_regime=str(row["vol_regime"]),
            trend_regime=str(row["trend_regime"]),
            structure_regime=str(row["structure_regime"]),
        )
        long_r = trade_outcome(records, pos, 1, rr)
        short_r = trade_outcome(records, pos, -1, rr)
        if long_r is None or short_r is None:
            continue
        signals = {name: int(row[f"sig_{name}"]) for name in STRATEGIES}
        events.append(
            BacktestEvent(
                context=context,
                signals=signals,
                coordinated_long_return_r=float(long_r),
                coordinated_short_return_r=float(short_r),
                execution_cost_r=cost_r,
            )
        )
    return events


def serialize_metrics(metrics):
    return {
        "members": list(metrics.members),
        "direction": "LONG" if metrics.direction == 1 else "SHORT",
        "trades": metrics.trades,
        "wins": metrics.wins,
        "win_rate": metrics.win_rate,
        "expectancy_r": metrics.expectancy_r,
        "profit_factor": metrics.profit_factor if metrics.profit_factor != float("inf") else "inf",
        "max_drawdown_r": metrics.max_drawdown_r,
        "total_r": metrics.total_r,
        "best_member_win_rate": metrics.best_member_win_rate,
        "win_rate_uplift": metrics.win_rate_uplift,
    }


def main():
    key = os.getenv("DATABENTO_API_KEY", "")
    if not key:
        raise SystemExit("DATABENTO_API_KEY secret is missing")

    session_count = int(os.getenv("DISCOVERY_SESSIONS", "10"))
    cost_r = float(os.getenv("DISCOVERY_COST_R", "0.03"))
    end = datetime(2026, 9, 11, tzinfo=TZ)
    dates = weekdays(end, session_count)
    client = db.Historical(key)
    out = Path("strategy_discovery_output")
    out.mkdir(exist_ok=True)

    raw_frames = []
    by_symbol_frames = defaultdict(list)
    for d in dates:
        start_date = d - timedelta(days=1)
        data = client.timeseries.get_range(
            dataset="GLBX.MDP3",
            schema="ohlcv-1m",
            stype_in="continuous",
            symbols=SYMBOLS,
            start=utc_iso(start_date, 18, 0),
            end=utc_iso(d, 16, 0),
        )
        df = data.to_df()
        if df.empty:
            continue
        idx = pd.DatetimeIndex(df.index)
        if idx.tz is None:
            idx = idx.tz_localize("UTC")
        work = df.copy()
        work["local_time"] = idx.tz_convert(TZ)
        work["target_session_date"] = str(d)
        raw_frames.append(work.reset_index())
        for symbol, g in work.groupby("symbol"):
            by_symbol_frames[str(symbol)].append(g.copy())

    if not raw_frames:
        raise SystemExit("No Databento rows returned")
    pd.concat(raw_frames, ignore_index=True).to_csv(out / "raw_1m_broad_sessions.csv", index=False)

    backtester = CoalitionBacktester()
    mc_engine = MonteCarloRobustnessEngine()
    all_results = []
    signal_counts = {}

    for symbol, frames in by_symbol_frames.items():
        g = pd.concat(frames).sort_values("local_time")
        # Remove duplicate timestamps that can arise at session boundaries.
        g = g[~g.index.duplicated(keep="first")].copy()
        g = enrich_symbol(g)
        signal_counts[symbol] = {
            name: int((g[f"sig_{name}"] != 0).sum()) for name in STRATEGIES
        }

        for rr in RR_CANDIDATES:
            events = build_events(g, symbol, rr, cost_r)
            grouped = defaultdict(list)
            for event in events:
                # Search only directional trend regimes; sideways remains NO_TRADE.
                if event.context.trend_regime not in {"bullish", "bearish"}:
                    continue
                grouped[event.context].append(event)

            for context, context_events in grouped.items():
                if len(context_events) < 50:
                    continue
                direction = 1 if context.trend_regime == "bullish" else -1
                survivors = backtester.train_oos_search(
                    context_events,
                    STRATEGIES,
                    direction,
                    train_fraction=0.70,
                    member_sizes=(2, 3, 4),
                    min_train_trades=15,
                    min_oos_trades=5,
                    top_n_train=20,
                )
                if not survivors:
                    continue

                split = max(1, min(len(context_events) - 1, int(len(context_events) * 0.70)))
                oos_events = context_events[split:]
                for train_metrics, oos_metrics in survivors[:3]:
                    oos_returns = backtester.returns_for(oos_events, oos_metrics.members, direction)
                    if len(oos_returns) < 5:
                        continue
                    mc = mc_engine.run(
                        oos_returns,
                        MonteCarloConfig(
                            iterations=500,
                            seed=17,
                            omit_trade_probability=0.03,
                            extra_cost_r=0.01,
                            slippage_r_std=0.02,
                            ruin_drawdown_r=8.0,
                        ),
                    )
                    all_results.append(
                        {
                            "symbol": symbol,
                            "rr": rr,
                            "context": {
                                "session": context.session,
                                "minutes_from_open_bucket": context.minutes_from_open_bucket,
                                "volatility_regime": context.volatility_regime,
                                "trend_regime": context.trend_regime,
                                "structure_regime": context.structure_regime,
                            },
                            "train": serialize_metrics(train_metrics),
                            "oos": serialize_metrics(oos_metrics),
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
                        }
                    )

    all_results.sort(
        key=lambda row: (
            row["monte_carlo_oos"]["ruin_probability"],
            -row["oos"]["win_rate"],
            -row["oos"]["expectancy_r"],
        )
    )
    summary = {
        "sessions_requested": session_count,
        "symbols": SYMBOLS,
        "strategies": STRATEGIES,
        "rr_candidates": RR_CANDIDATES,
        "execution_cost_r_assumption": cost_r,
        "signal_counts": signal_counts,
        "surviving_directional_coalitions": len(all_results),
        "top_results": all_results[:30],
        "research_notes": [
            "OHLCV-1m only; no MBP/trades/order-flow yet.",
            "Signals are evaluated at bar close with next-bar entry.",
            "Same-bar target/stop ambiguity is resolved conservatively as stop-first.",
            "Session labels outside NY cash are research proxies, not official venue session definitions.",
            "Results are preliminary seeds and cannot be promoted without larger OOS/walk-forward/Monte Carlo/PBO/DSR validation.",
            "Live money remains disabled."
        ],
    }
    with open(out / "discovery_summary.json", "w", encoding="utf-8") as f:
        json.dump(summary, f, indent=2)
    with open(out / "all_coalitions.json", "w", encoding="utf-8") as f:
        json.dump(all_results, f, indent=2)

    print("REAL_STRATEGY_DISCOVERY_OK")
    print(json.dumps({
        "sessions_requested": session_count,
        "surviving_directional_coalitions": len(all_results),
        "top_results": all_results[:5],
    }, indent=2))


if __name__ == "__main__":
    main()
