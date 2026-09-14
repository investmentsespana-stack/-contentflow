"""Discovery-only V3: preserve the user's 3/9 trigger, measure 9/20 ratification.

Core setup and 3-bar/40%-Bollinger exit remain unchanged. V3 replaces the
previous non-lateral filter with a simple causal EMA9 slope sign and records
whether EMA9/EMA20 is already aligned or freshly ratifies during the trade.
"""
from __future__ import annotations

import json
import os
from collections import Counter
from pathlib import Path

import numpy as np
import pandas as pd

import bollinger_ema_sar_v1_backtest as base

OUT = Path("bollinger_ema_sar_v3_ratification_output")


def states_and_crosses(g: pd.DataFrame):
    c39_up = (g["ema3"].shift(1) <= g["ema9"].shift(1)) & (g["ema3"] > g["ema9"])
    c39_dn = (g["ema3"].shift(1) >= g["ema9"].shift(1)) & (g["ema3"] < g["ema9"])
    s39 = pd.Series(np.nan, index=g.index, dtype=float)
    s39.loc[c39_up] = 1.0
    s39.loc[c39_dn] = -1.0
    s39 = s39.ffill().fillna(0.0)

    c920_up = (g["ema9"].shift(1) <= g["ema20"].shift(1)) & (g["ema9"] > g["ema20"])
    c920_dn = (g["ema9"].shift(1) >= g["ema20"].shift(1)) & (g["ema9"] < g["ema20"])
    s920 = pd.Series(np.nan, index=g.index, dtype=float)
    s920.loc[c920_up] = 1.0
    s920.loc[c920_dn] = -1.0
    s920 = s920.ffill().fillna(0.0)
    return c39_up.fillna(False), c39_dn.fillna(False), s39, c920_up.fillna(False), c920_dn.fillna(False), s920


def signal_masks_v3(g: pd.DataFrame):
    rl, rs, el, es = base.candle_patterns(g)
    c39_up, c39_dn, s39, c920_up, c920_dn, s920 = states_and_crosses(g)
    prev_struct_low = g["confirmed_swing_low"].shift(1)
    prev_struct_high = g["confirmed_swing_high"].shift(1)

    long_parts = {
        "structure_sweep_reclaim": (g["low"].shift(1) < prev_struct_low) & (g["close"] > prev_struct_low),
        "bollinger_touch": (g["low"].shift(1) <= g["bb_lower"].shift(1)) | (g["low"] <= g["bb_lower"]),
        "ema9_directional_slope": g["ema9"] > g["ema9"].shift(1),
        "ema3_9_cross": c39_up,
        "close_vs_ema9": g["close"] > g["ema9"],
        "psar": g["psar"] < g["low"],
        "signal_shape": g["low"] > g["low"].shift(1),
        "pattern": rl | el,
    }
    short_parts = {
        "structure_sweep_reclaim": (g["high"].shift(1) > prev_struct_high) & (g["close"] < prev_struct_high),
        "bollinger_touch": (g["high"].shift(1) >= g["bb_upper"].shift(1)) | (g["high"] >= g["bb_upper"]),
        "ema9_directional_slope": g["ema9"] < g["ema9"].shift(1),
        "ema3_9_cross": c39_dn,
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

    return (
        long_parts,
        short_parts,
        combine(long_parts),
        combine(short_parts),
        (rl, rs, el, es),
        (c39_up, c39_dn, s39, c920_up, c920_dn, s920),
    )


def ratification_for_trade(g, signal_i, result, direction, state_pack):
    _, _, s39, c920_up, c920_dn, s920 = state_pack
    aligned_at_signal = bool(g.at[signal_i, "ema9"] > g.at[signal_i, "ema20"]) if direction == 1 else bool(g.at[signal_i, "ema9"] < g.at[signal_i, "ema20"])
    event_series = c920_up if direction == 1 else c920_dn
    event_i = None
    for j in range(int(result["entry_i"]), int(result["exit_i"]) + 1):
        if bool(event_series.iloc[j]):
            event_i = j
            break
    fresh_during_trade = event_i is not None
    bars_to = (event_i - int(result["entry_i"]) + 1) if event_i is not None else None
    if aligned_at_signal:
        category = "already_aligned_at_signal"
    elif fresh_during_trade:
        category = "fresh_9_20_ratification_during_trade"
    else:
        category = "unratified_within_3_bars"
    return {
        "ema3_9_state": int(s39.iloc[signal_i]),
        "ema9_20_state": int(s920.iloc[signal_i]),
        "ema9_20_aligned_at_signal": aligned_at_signal,
        "ema9_20_fresh_ratification_during_trade": fresh_during_trade,
        "bars_to_9_20_ratification": bars_to,
        "ratification_category": category,
    }


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")

    OUT.mkdir(exist_ok=True)
    g = base.enrich(base.load_market(symbol))
    long_parts, short_parts, long_mask, short_mask, pats, state_pack = signal_masks_v3(g)

    trades = []
    i = 205
    while i < len(g) - 1:
        long_ok = bool(long_mask.iloc[i])
        short_ok = bool(short_mask.iloc[i])
        if long_ok == short_ok:
            i += 1
            continue
        direction = 1 if long_ok else -1
        result = base.run_trade(g, i, direction)
        if result is None:
            i += 1
            continue

        row = g.iloc[i]
        prev = g.iloc[i - 1]
        rat = ratification_for_trade(g, i, result, direction, state_pack)
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
            "ema9_slope_1bar": float(row["ema9"] - g.iloc[i - 1]["ema9"]),
            "close_above_ema50": bool(row["close"] > row["ema50"]),
            "close_above_ema200": bool(row["close"] > row["ema200"]),
            "ema50_above_ema200": bool(row["ema50"] > row["ema200"]),
            **rat,
            **{k: v for k, v in result.items() if not k.endswith("_i")},
        }
        trades.append(rec)
        i = int(result["exit_i"]) + 1

    tdf = pd.DataFrame(trades)
    tdf.to_csv(OUT / f"{symbol.replace('.', '_')}_trades.csv", index=False)

    summary = {
        "strategy": "bollinger_ema_sar_v3_ratification",
        "symbol": symbol,
        "window": [str(base.START), str(base.END)],
        "timeframe": "1m",
        "live_money": False,
        "exit_rule": "40% Bollinger bandwidth target OR max 3 bars; 9/20 does not alter exit in V3",
        "overall": base.metrics(trades),
        "by_direction": {},
        "by_session": {},
        "by_pattern": {},
        "by_ratification": {},
        "exit_reasons": dict(Counter(r["exit_reason"] for r in trades)),
        "filter_funnel": {
            "LONG": base.cumulative_funnel(long_parts),
            "SHORT": base.cumulative_funnel(short_parts),
        },
    }
    for direction in ("LONG", "SHORT"):
        subset = [r for r in trades if r["direction"] == direction]
        summary["by_direction"][direction] = base.metrics(subset)
    for sess in sorted({r["session"] for r in trades}):
        summary["by_session"][sess] = base.metrics([r for r in trades if r["session"] == sess])
    for pat in sorted({r["pattern"] for r in trades}):
        summary["by_pattern"][pat] = base.metrics([r for r in trades if r["pattern"] == pat])
    for cat in sorted({r["ratification_category"] for r in trades}):
        summary["by_ratification"][cat] = base.metrics([r for r in trades if r["ratification_category"] == cat])

    (OUT / f"{symbol.replace('.', '_')}_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
