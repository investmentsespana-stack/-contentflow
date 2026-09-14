"""Discovery-only V4: V3 entries with three consecutive trade-color candles exit.

All signal decisions use closed bars. Entry remains next-bar open. The 40% Bollinger
profit target and three-total-bar timeout are disabled. Profit exit occurs only at
the close of the third consecutive candle matching trade direction; stop remains
active intrabar.
"""
from __future__ import annotations

import json
import os
from collections import Counter
from pathlib import Path

import numpy as np
import pandas as pd

import bollinger_ema_sar_v1_backtest as base
import bollinger_ema_sar_v3_backtest as v3

OUT = Path("bollinger_ema_sar_v4_output")
COST_R = base.COST_R


def run_trade_v4(g: pd.DataFrame, signal_i: int, direction: int):
    entry_i = signal_i + 1
    if entry_i >= len(g):
        return None

    entry = float(g.at[entry_i, "open"])
    if direction == 1:
        stop = float(g.at[signal_i - 1, "low"])
        if not (entry > stop):
            return None
        risk = entry - stop
    else:
        stop = float(g.at[signal_i - 1, "high"])
        if not (entry < stop):
            return None
        risk = stop - entry
    if risk <= 0:
        return None

    consecutive = 0
    max_consecutive = 0
    exit_i = len(g) - 1
    exit_price = float(g.at[exit_i, "close"])
    exit_reason = "dataset_end"

    for j in range(entry_i, len(g)):
        high = float(g.at[j, "high"])
        low = float(g.at[j, "low"])
        opn = float(g.at[j, "open"])
        close = float(g.at[j, "close"])

        stop_hit = low <= stop if direction == 1 else high >= stop
        if stop_hit:
            exit_i = j
            exit_price = stop
            exit_reason = "stop"
            break

        same_color = close > opn if direction == 1 else close < opn
        if same_color:
            consecutive += 1
            max_consecutive = max(max_consecutive, consecutive)
        else:
            consecutive = 0

        if consecutive >= 3:
            exit_i = j
            exit_price = close
            exit_reason = "three_consecutive_trade_color"
            break

    pnl_points = direction * (exit_price - entry)
    gross_r = pnl_points / risk
    net_r = gross_r - COST_R
    return {
        "entry_i": entry_i,
        "exit_i": exit_i,
        "entry": entry,
        "stop": stop,
        "exit": exit_price,
        "exit_reason": exit_reason,
        "risk_points": risk,
        "pnl_points": pnl_points,
        "gross_r": gross_r,
        "net_r": net_r,
        "bars_held": exit_i - entry_i + 1,
        "max_consecutive_trade_color": max_consecutive,
    }


def profit_factor(vals):
    gp = sum(x for x in vals if x > 0)
    gl = abs(sum(x for x in vals if x < 0))
    return gp / gl if gl > 0 else (float("inf") if gp > 0 else 0.0)


def max_dd(vals):
    eq = peak = dd = 0.0
    for x in vals:
        eq += float(x)
        peak = max(peak, eq)
        dd = max(dd, peak - eq)
    return dd


def metrics(rows):
    net = [float(r["net_r"]) for r in rows]
    gross = [float(r["gross_r"]) for r in rows]
    n = len(rows)
    return {
        "trades": n,
        "gross_total_r": float(sum(gross)),
        "net_total_r": float(sum(net)),
        "net_expectancy_r": float(np.mean(net)) if net else 0.0,
        "net_profit_factor": float(profit_factor(net)),
        "net_win_rate": float(sum(x > 0 for x in net) / n) if n else 0.0,
        "net_max_drawdown_r": float(max_dd(net)),
        "three_color_exit_rate": float(sum(r["exit_reason"] == "three_consecutive_trade_color" for r in rows) / n) if n else 0.0,
        "stop_hit_rate": float(sum(r["exit_reason"] == "stop" for r in rows) / n) if n else 0.0,
        "dataset_end_rate": float(sum(r["exit_reason"] == "dataset_end" for r in rows) / n) if n else 0.0,
        "mean_bars_held": float(np.mean([r["bars_held"] for r in rows])) if n else 0.0,
        "median_bars_held": float(np.median([r["bars_held"] for r in rows])) if n else 0.0,
    }


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")

    OUT.mkdir(exist_ok=True)
    g = base.enrich(base.load_market(symbol))
    long_parts, short_parts, long_mask, short_mask, pats = v3.signal_masks_v3(g)

    trades = []
    i = 205
    while i < len(g) - 1:
        long_ok = bool(long_mask.iloc[i])
        short_ok = bool(short_mask.iloc[i])
        if long_ok == short_ok:
            i += 1
            continue

        direction = 1 if long_ok else -1
        result = run_trade_v4(g, i, direction)
        if result is None:
            i += 1
            continue

        row = g.iloc[i]
        prev = g.iloc[i - 1]
        aligned, crossed_signal, crossed_during, phase = v3.ema9_20_diagnostics(
            g, i, direction, int(result["exit_i"])
        )
        rec = {
            "symbol": symbol,
            "direction": "LONG" if direction == 1 else "SHORT",
            "signal_time_et": str(row["local_time"]),
            "entry_time_et": str(g.iloc[result["entry_i"]]["local_time"]),
            "exit_time_et": str(g.iloc[result["exit_i"]]["local_time"]),
            "session": str(row["session"]),
            "pattern": base.pattern_name(i, direction, pats),
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
            "ema3_slope_1": float(row["ema3"] - g.iloc[i - 1]["ema3"]),
            "ema9_slope_1": float(row["ema9"] - g.iloc[i - 1]["ema9"]),
            "ema9_20_aligned_at_signal": aligned,
            "ema9_20_cross_on_signal": crossed_signal,
            "ema9_20_cross_during_trade": crossed_during,
            "ema9_20_phase": phase,
            "close_above_ema50": bool(row["close"] > row["ema50"]),
            "close_above_ema200": bool(row["close"] > row["ema200"]),
            "ema50_above_ema200": bool(row["ema50"] > row["ema200"]),
            **{k: v for k, v in result.items() if not k.endswith("_i")},
        }
        trades.append(rec)
        i = int(result["exit_i"]) + 1

    tdf = pd.DataFrame(trades)
    tdf.to_csv(OUT / f"{symbol.replace('.', '_')}_trades.csv", index=False)

    summary = {
        "strategy": "bollinger_ema_sar_v4_three_color_exit",
        "symbol": symbol,
        "window": [str(base.START), str(base.END)],
        "timeframe": "1m",
        "live_money": False,
        "entry_logic": "V3 crossover-derived non-lateral filter; all other entry conditions unchanged",
        "exit_rule": "stop active; profit exit only at close of third consecutive trade-color candle; opposite color or doji resets count; no 40% Bollinger target; no 3-total-bar timeout",
        "overall": metrics(trades),
        "by_direction": {},
        "by_session": {},
        "by_pattern": {},
        "by_ema9_20_phase": {},
        "exit_reasons": dict(Counter(r["exit_reason"] for r in trades)),
        "filter_funnel": {
            "LONG": base.cumulative_funnel(long_parts),
            "SHORT": base.cumulative_funnel(short_parts),
        },
    }

    for direction in ("LONG", "SHORT"):
        subset = [r for r in trades if r["direction"] == direction]
        summary["by_direction"][direction] = metrics(subset)
    for sess in sorted({r["session"] for r in trades}):
        summary["by_session"][sess] = metrics([r for r in trades if r["session"] == sess])
    for pat in sorted({r["pattern"] for r in trades}):
        summary["by_pattern"][pat] = metrics([r for r in trades if r["pattern"] == pat])
    for phase_name in sorted({r["ema9_20_phase"] for r in trades}):
        summary["by_ema9_20_phase"][phase_name] = metrics([r for r in trades if r["ema9_20_phase"] == phase_name])

    (OUT / f"{symbol.replace('.', '_')}_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
