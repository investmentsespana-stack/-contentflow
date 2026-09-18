"""Discovery-only backtest for the preregistered 1m Bollinger/EMA/SAR setup.

This script intentionally uses only 2025-09-25..2026-09-11 and does not touch
confirmatory or sealed holdout windows. All entry decisions are based on fully
closed bars; execution is at the next bar open. V1B changes only the sideways/slope
filter: EMA20 net movement over 5 closed bars must be at least 5% of current
Bollinger bandwidth in the trade direction; no monotonic-bar requirement.
"""
from __future__ import annotations

import json
import math
import os
from collections import Counter, defaultdict
from datetime import date, datetime, time, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

import databento as db
import numpy as np
import pandas as pd

START = date(2025, 9, 25)
END = date(2026, 9, 11)
TZ = ZoneInfo("America/New_York")
UTC = ZoneInfo("UTC")
SYMBOLS = {"ES.v.0", "NQ.v.0", "YM.v.0", "RTY.v.0"}
OUT = Path("bollinger_ema_sar_v1bb_output")
COST_R = 0.03


def utc_iso(d: date, hh: int, mm: int = 0) -> str:
    local = datetime.combine(d, time(hh, mm), TZ)
    return local.astimezone(UTC).isoformat().replace("+00:00", "Z")


def session_label(ts: pd.Timestamp) -> str:
    t = ts.time()
    if t >= time(18, 0): return "globex_evening"
    if t < time(2, 0): return "overnight_early"
    if t < time(8, 0): return "europe"
    if t < time(9, 30): return "pre_ny_cash"
    if t < time(11, 0): return "ny_open_0_90"
    if t < time(14, 0): return "ny_midday"
    if t < time(16, 0): return "ny_afternoon"
    return "globex_transition"


def parabolic_sar(high: pd.Series, low: pd.Series, close: pd.Series,
                  step: float = 0.02, max_step: float = 0.20) -> pd.Series:
    """Causal classic PSAR implementation with standard 0.02/0.20 settings."""
    h = high.astype(float).to_numpy()
    l = low.astype(float).to_numpy()
    c = close.astype(float).to_numpy()
    n = len(h)
    out = np.full(n, np.nan)
    if n < 2:
        return pd.Series(out, index=high.index)
    bull = bool(c[1] >= c[0])
    out[0] = l[0] if bull else h[0]
    ep = h[0] if bull else l[0]
    af = step
    for i in range(1, n):
        prev = out[i - 1]
        cur = prev + af * (ep - prev)
        if bull:
            cur = min(cur, l[i - 1])
            if i >= 2:
                cur = min(cur, l[i - 2])
            if l[i] < cur:
                bull = False
                cur = ep
                ep = l[i]
                af = step
            elif h[i] > ep:
                ep = h[i]
                af = min(max_step, af + step)
        else:
            cur = max(cur, h[i - 1])
            if i >= 2:
                cur = max(cur, h[i - 2])
            if h[i] > cur:
                bull = True
                cur = ep
                ep = h[i]
                af = step
            elif l[i] < ep:
                ep = l[i]
                af = min(max_step, af + step)
        out[i] = cur
    return pd.Series(out, index=high.index)


def load_market(symbol: str) -> pd.DataFrame:
    key = os.getenv("DATABENTO_API_KEY", "")
    if not key:
        raise SystemExit("DATABENTO_API_KEY secret is missing")
    client = db.Historical(key)
    # Begin the prior futures evening so the first discovery calendar date has context.
    data = client.timeseries.get_range(
        dataset="GLBX.MDP3",
        schema="ohlcv-1m",
        stype_in="continuous",
        symbols=[symbol],
        start=utc_iso(START - timedelta(days=1), 18, 0),
        end=utc_iso(END, 17, 0),
    )
    df = data.to_df()
    if df.empty:
        raise SystemExit(f"No 1m data returned for {symbol}")
    idx = pd.DatetimeIndex(df.index)
    if idx.tz is None:
        idx = idx.tz_localize("UTC")
    g = df.copy()
    g["local_time"] = idx.tz_convert(TZ)
    g = g.sort_values("local_time")
    g = g[~g.index.duplicated(keep="first")].copy()
    local_d = g["local_time"].dt.date
    g = g[(local_d >= START) & (local_d <= END)].reset_index(drop=True)
    return g


def enrich(g: pd.DataFrame) -> pd.DataFrame:
    g = g.copy()
    close = g["close"].astype(float)
    for p in (3, 9, 20, 50, 200):
        g[f"ema{p}"] = close.ewm(span=p, adjust=False, min_periods=p).mean()

    mid = close.rolling(20, min_periods=20).mean()
    std = close.rolling(20, min_periods=20).std(ddof=0)
    g["bb_mid"] = mid
    g["bb_upper"] = mid + 2.0 * std
    g["bb_lower"] = mid - 2.0 * std
    g["bb_width"] = g["bb_upper"] - g["bb_lower"]
    g["psar"] = parabolic_sar(g["high"], g["low"], g["close"])

    # 2-left / 2-right swing, made causal by shifting the detected level two bars.
    lo = g["low"].astype(float)
    hi = g["high"].astype(float)
    swing_low_raw = (
        (lo < lo.shift(1)) & (lo < lo.shift(2)) &
        (lo < lo.shift(-1)) & (lo < lo.shift(-2))
    )
    swing_high_raw = (
        (hi > hi.shift(1)) & (hi > hi.shift(2)) &
        (hi > hi.shift(-1)) & (hi > hi.shift(-2))
    )
    slv = lo.where(swing_low_raw)
    shv = hi.where(swing_high_raw)
    g["confirmed_swing_low"] = slv.shift(2).ffill()
    g["confirmed_swing_high"] = shv.shift(2).ffill()
    g["session"] = [session_label(x) for x in g["local_time"]]
    return g


def candle_patterns(g: pd.DataFrame):
    o = g["open"].astype(float)
    c = g["close"].astype(float)
    h = g["high"].astype(float)
    l = g["low"].astype(float)
    body = (c - o).abs()
    lower_wick = np.minimum(o, c) - l
    upper_wick = h - np.maximum(o, c)

    rocket_long = (c > o) & (body > 0) & (lower_wick >= 0.70 * body)
    rocket_short = (c < o) & (body > 0) & (upper_wick >= 0.70 * body)

    prev_lo_body = np.minimum(o.shift(1), c.shift(1))
    prev_hi_body = np.maximum(o.shift(1), c.shift(1))
    this_lo_body = np.minimum(o, c)
    this_hi_body = np.maximum(o, c)
    engulf_long = (c > o) & (this_lo_body <= prev_lo_body) & (this_hi_body >= prev_hi_body)
    engulf_short = (c < o) & (this_lo_body <= prev_lo_body) & (this_hi_body >= prev_hi_body)
    return rocket_long.fillna(False), rocket_short.fillna(False), engulf_long.fillna(False), engulf_short.fillna(False)


def signal_masks(g: pd.DataFrame):
    rl, rs, el, es = candle_patterns(g)
    prev_struct_low = g["confirmed_swing_low"].shift(1)
    prev_struct_high = g["confirmed_swing_high"].shift(1)

    long_parts = {
        "structure_sweep_reclaim": (g["low"].shift(1) < prev_struct_low) & (g["close"] > prev_struct_low),
        "bollinger_touch": (g["low"].shift(1) <= g["bb_lower"].shift(1)) | (g["low"] <= g["bb_lower"]),
        "ema20_slope": (g["ema20"] - g["ema20"].shift(5)) >= (0.05 * g["bb_width"]),
        "ema3_9_cross": (g["ema3"].shift(1) <= g["ema9"].shift(1)) & (g["ema3"] > g["ema9"]),
        "close_vs_ema9": g["close"] > g["ema9"],
        "psar": g["psar"] < g["low"],
        "signal_shape": g["low"] > g["low"].shift(1),
        "pattern": rl | el,
    }
    short_parts = {
        "structure_sweep_reclaim": (g["high"].shift(1) > prev_struct_high) & (g["close"] < prev_struct_high),
        "bollinger_touch": (g["high"].shift(1) >= g["bb_upper"].shift(1)) | (g["high"] >= g["bb_upper"]),
        "ema20_slope": (g["ema20"] - g["ema20"].shift(5)) <= (-0.05 * g["bb_width"]),
        "ema3_9_cross": (g["ema3"].shift(1) >= g["ema9"].shift(1)) & (g["ema3"] < g["ema9"]),
        "close_vs_ema9": g["close"] < g["ema9"],
        "psar": g["psar"] > g["high"],
        "signal_shape": g["high"] < g["high"].shift(1),
        "pattern": rs | es,
    }

    def combine(parts):
        out = pd.Series(True, index=g.index)
        for v in parts.values():
            out &= v.fillna(False)
        return out

    return long_parts, short_parts, combine(long_parts), combine(short_parts), (rl, rs, el, es)


def pattern_name(i: int, direction: int, pats) -> str:
    rl, rs, el, es = pats
    rocket = bool(rl.iloc[i] if direction == 1 else rs.iloc[i])
    engulf = bool(el.iloc[i] if direction == 1 else es.iloc[i])
    if rocket and engulf: return "rocket+engulfing"
    if rocket: return "rocket"
    return "engulfing"


def cumulative_funnel(parts: dict[str, pd.Series]) -> dict[str, int]:
    active = pd.Series(True, index=next(iter(parts.values())).index)
    out = {}
    for name, mask in parts.items():
        active &= mask.fillna(False)
        out[name] = int(active.sum())
    return out


def run_trade(g: pd.DataFrame, signal_i: int, direction: int):
    entry_i = signal_i + 1
    if entry_i >= len(g):
        return None
    entry = float(g.at[entry_i, "open"])
    width = float(g.at[signal_i, "bb_width"])
    if not math.isfinite(width) or width <= 0:
        return None
    if direction == 1:
        stop = float(g.at[signal_i - 1, "low"])
        if not (entry > stop): return None
        target = entry + 0.40 * width
        risk = entry - stop
    else:
        stop = float(g.at[signal_i - 1, "high"])
        if not (entry < stop): return None
        target = entry - 0.40 * width
        risk = stop - entry
    if risk <= 0:
        return None

    last_i = min(len(g) - 1, entry_i + 2)  # exactly up to 3 one-minute bars
    exit_i = last_i
    exit_price = float(g.at[last_i, "close"])
    exit_reason = "time_3_bars"

    for j in range(entry_i, last_i + 1):
        high = float(g.at[j, "high"])
        low = float(g.at[j, "low"])
        if direction == 1:
            stop_hit = low <= stop
            target_hit = high >= target
        else:
            stop_hit = high >= stop
            target_hit = low <= target
        # Conservative OHLC ambiguity: if both are possible in the same minute, stop first.
        if stop_hit:
            exit_i, exit_price, exit_reason = j, stop, "stop"
            break
        if target_hit:
            exit_i, exit_price, exit_reason = j, target, "target_40pct_bb"
            break

    pnl_points = direction * (exit_price - entry)
    gross_r = pnl_points / risk
    net_r = gross_r - COST_R
    return {
        "entry_i": entry_i,
        "exit_i": exit_i,
        "entry": entry,
        "stop": stop,
        "target": target,
        "exit": exit_price,
        "exit_reason": exit_reason,
        "risk_points": risk,
        "pnl_points": pnl_points,
        "gross_r": gross_r,
        "net_r": net_r,
        "bars_held": exit_i - entry_i + 1,
    }


def profit_factor(vals):
    gp = sum(x for x in vals if x > 0)
    gl = abs(sum(x for x in vals if x < 0))
    return gp / gl if gl > 0 else (float("inf") if gp > 0 else 0.0)


def max_dd(vals):
    eq = 0.0
    peak = 0.0
    dd = 0.0
    for x in vals:
        eq += float(x)
        peak = max(peak, eq)
        dd = max(dd, peak - eq)
    return dd


def metrics(rows):
    gross = [float(r["gross_r"]) for r in rows]
    net = [float(r["net_r"]) for r in rows]
    return {
        "trades": len(rows),
        "gross_total_r": float(sum(gross)),
        "net_total_r": float(sum(net)),
        "net_expectancy_r": float(np.mean(net)) if net else 0.0,
        "net_profit_factor": float(profit_factor(net)),
        "net_win_rate": float(sum(x > 0 for x in net) / len(net)) if net else 0.0,
        "net_max_drawdown_r": float(max_dd(net)),
        "target_hit_rate": float(sum(r["exit_reason"] == "target_40pct_bb" for r in rows) / len(rows)) if rows else 0.0,
        "stop_hit_rate": float(sum(r["exit_reason"] == "stop" for r in rows) / len(rows)) if rows else 0.0,
        "time_exit_rate": float(sum(r["exit_reason"] == "time_3_bars" for r in rows) / len(rows)) if rows else 0.0,
    }


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    if symbol not in SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")
    OUT.mkdir(exist_ok=True)
    g = enrich(load_market(symbol))
    long_parts, short_parts, long_mask, short_mask, pats = signal_masks(g)

    trades = []
    i = 205
    while i < len(g) - 1:
        long_ok = bool(long_mask.iloc[i])
        short_ok = bool(short_mask.iloc[i])
        if long_ok == short_ok:  # both false or conflict: no trade
            i += 1
            continue
        direction = 1 if long_ok else -1
        result = run_trade(g, i, direction)
        if result is None:
            i += 1
            continue
        row = g.iloc[i]
        prev = g.iloc[i - 1]
        rec = {
            "symbol": symbol,
            "direction": "LONG" if direction == 1 else "SHORT",
            "signal_time_et": str(row["local_time"]),
            "entry_time_et": str(g.iloc[result["entry_i"]]["local_time"]),
            "exit_time_et": str(g.iloc[result["exit_i"]]["local_time"]),
            "session": str(row["session"]),
            "pattern": pattern_name(i, direction, pats),
            "signal_open": float(row["open"]),
            "signal_high": float(row["high"]),
            "signal_low": float(row["low"]),
            "signal_close": float(row["close"]),
            "prior_low": float(prev["low"]),
            "prior_high": float(prev["high"]),
            "bb_width_signal": float(row["bb_width"]),
            "ema3": float(row["ema3"]),
            "ema9": float(row["ema9"]),
            "ema20": float(row["ema20"]),
            "ema50": float(row["ema50"]),
            "ema200": float(row["ema200"]),
            "close_above_ema50": bool(row["close"] > row["ema50"]),
            "close_above_ema200": bool(row["close"] > row["ema200"]),
            "ema50_above_ema200": bool(row["ema50"] > row["ema200"]),
            **{k: v for k, v in result.items() if not k.endswith("_i")},
        }
        trades.append(rec)
        # One position at a time; do not reuse the exit minute as a new signal.
        i = int(result["exit_i"]) + 1

    tdf = pd.DataFrame(trades)
    tdf.to_csv(OUT / f"{symbol.replace('.', '_')}_trades.csv", index=False)

    summary = {
        "strategy": "bollinger_ema_sar_v1b",
        "symbol": symbol,
        "window": [str(START), str(END)],
        "timeframe": "1m",
        "live_money": False,
        "exit_rule": "40% Bollinger bandwidth target OR max 3 bars; stop remains active; stop-first on same-bar ambiguity",
        "overall": metrics(trades),
        "by_direction": {},
        "by_session": {},
        "by_pattern": {},
        "exit_reasons": dict(Counter(r["exit_reason"] for r in trades)),
        "filter_funnel": {
            "LONG": cumulative_funnel(long_parts),
            "SHORT": cumulative_funnel(short_parts),
        },
    }
    for direction in ("LONG", "SHORT"):
        subset = [r for r in trades if r["direction"] == direction]
        summary["by_direction"][direction] = metrics(subset)
    for sess in sorted({r["session"] for r in trades}):
        summary["by_session"][sess] = metrics([r for r in trades if r["session"] == sess])
    for pat in sorted({r["pattern"] for r in trades}):
        summary["by_pattern"][pat] = metrics([r for r in trades if r["pattern"] == pat])

    (OUT / f"{symbol.replace('.', '_')}_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
