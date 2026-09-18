"""Controlled slope-filter study for Bollinger/EMA/SAR V1.

Discovery only. Keeps the V1 setup fixed and changes only the interpretation
of "market has slope / not sideways".
"""
from __future__ import annotations

import json
import os
from collections import Counter
from pathlib import Path

import numpy as np
import pandas as pd

from bollinger_ema_sar_v1_backtest import (
    START, END, SYMBOLS, enrich, load_market, candle_patterns,
    run_trade, metrics, pattern_name, cumulative_funnel,
)

OUT = Path("bollinger_ema_sar_v1_1_output")
VARIANTS = ("A_MONOTONIC3", "B_NET3", "C_ATR5")


def add_atr(g: pd.DataFrame) -> pd.DataFrame:
    g = g.copy()
    prev_close = g["close"].astype(float).shift(1)
    tr = pd.concat([
        g["high"].astype(float) - g["low"].astype(float),
        (g["high"].astype(float) - prev_close).abs(),
        (g["low"].astype(float) - prev_close).abs(),
    ], axis=1).max(axis=1)
    g["atr14"] = tr.rolling(14, min_periods=14).mean()
    return g


def slope_masks(g: pd.DataFrame, variant: str):
    e = g["ema20"].astype(float)
    if variant == "A_MONOTONIC3":
        long = (e > e.shift(1)) & (e.shift(1) > e.shift(2)) & (e.shift(2) > e.shift(3))
        short = (e < e.shift(1)) & (e.shift(1) < e.shift(2)) & (e.shift(2) < e.shift(3))
    elif variant == "B_NET3":
        long = e > e.shift(3)
        short = e < e.shift(3)
    elif variant == "C_ATR5":
        delta = e - e.shift(5)
        threshold = 0.05 * g["atr14"].astype(float)
        long = delta >= threshold
        short = delta <= -threshold
    else:
        raise ValueError(variant)
    return long.fillna(False), short.fillna(False)


def signal_masks(g: pd.DataFrame, variant: str):
    rl, rs, el, es = candle_patterns(g)
    prev_struct_low = g["confirmed_swing_low"].shift(1)
    prev_struct_high = g["confirmed_swing_high"].shift(1)
    slope_long, slope_short = slope_masks(g, variant)

    long_parts = {
        "structure_sweep_reclaim": (g["low"].shift(1) < prev_struct_low) & (g["close"] > prev_struct_low),
        "bollinger_touch": (g["low"].shift(1) <= g["bb_lower"].shift(1)) | (g["low"] <= g["bb_lower"]),
        "slope_filter": slope_long,
        "ema3_9_cross": (g["ema3"].shift(1) <= g["ema9"].shift(1)) & (g["ema3"] > g["ema9"]),
        "close_vs_ema9": g["close"] > g["ema9"],
        "psar": g["psar"] < g["low"],
        "signal_shape": g["low"] > g["low"].shift(1),
        "pattern": rl | el,
    }
    short_parts = {
        "structure_sweep_reclaim": (g["high"].shift(1) > prev_struct_high) & (g["close"] < prev_struct_high),
        "bollinger_touch": (g["high"].shift(1) >= g["bb_upper"].shift(1)) | (g["high"] >= g["bb_upper"]),
        "slope_filter": slope_short,
        "ema3_9_cross": (g["ema3"].shift(1) >= g["ema9"].shift(1)) & (g["ema3"] < g["ema9"]),
        "close_vs_ema9": g["close"] < g["ema9"],
        "psar": g["psar"] > g["high"],
        "signal_shape": g["high"] < g["high"].shift(1),
        "pattern": rs | es,
    }

    def combine(parts):
        out = pd.Series(True, index=g.index)
        for mask in parts.values():
            out &= mask.fillna(False)
        return out

    return long_parts, short_parts, combine(long_parts), combine(short_parts), (rl, rs, el, es)


def run_variant(g: pd.DataFrame, symbol: str, variant: str):
    long_parts, short_parts, long_mask, short_mask, pats = signal_masks(g, variant)
    trades = []
    i = 205
    while i < len(g) - 1:
        long_ok = bool(long_mask.iloc[i])
        short_ok = bool(short_mask.iloc[i])
        if long_ok == short_ok:
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
            "variant": variant,
            "symbol": symbol,
            "direction": "LONG" if direction == 1 else "SHORT",
            "signal_time_et": str(row["local_time"]),
            "entry_time_et": str(g.iloc[result["entry_i"]]["local_time"]),
            "exit_time_et": str(g.iloc[result["exit_i"]]["local_time"]),
            "session": str(row["session"]),
            "pattern": pattern_name(i, direction, pats),
            "bb_width_signal": float(row["bb_width"]),
            "ema20": float(row["ema20"]),
            "atr14": float(row["atr14"]),
            "ema20_delta3": float(row["ema20"] - g.iloc[i-3]["ema20"]),
            "ema20_delta5": float(row["ema20"] - g.iloc[i-5]["ema20"]),
            "ema50": float(row["ema50"]),
            "ema200": float(row["ema200"]),
            "prior_low": float(prev["low"]),
            "prior_high": float(prev["high"]),
            **{k: v for k, v in result.items() if not k.endswith("_i")},
        }
        trades.append(rec)
        i = int(result["exit_i"]) + 1

    summary = {
        "variant": variant,
        "symbol": symbol,
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
        summary["by_direction"][direction] = metrics([r for r in trades if r["direction"] == direction])
    for sess in sorted({r["session"] for r in trades}):
        summary["by_session"][sess] = metrics([r for r in trades if r["session"] == sess])
    for pat in sorted({r["pattern"] for r in trades}):
        summary["by_pattern"][pat] = metrics([r for r in trades if r["pattern"] == pat])
    return trades, summary


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    if symbol not in SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")
    OUT.mkdir(exist_ok=True)
    g = add_atr(enrich(load_market(symbol)))

    all_trades = []
    summaries = {}
    for variant in VARIANTS:
        trades, summary = run_variant(g, symbol, variant)
        all_trades.extend(trades)
        summaries[variant] = summary

    pd.DataFrame(all_trades).to_csv(OUT / f"{symbol.replace('.', '_')}_slope_study_trades.csv", index=False)
    payload = {
        "study": "bollinger_ema_sar_v1_1_slope_study",
        "symbol": symbol,
        "window": [str(START), str(END)],
        "timeframe": "1m",
        "live_money": False,
        "only_changed_variable": "slope/non-sideways filter",
        "variants": summaries,
    }
    (OUT / f"{symbol.replace('.', '_')}_slope_study_summary.json").write_text(
        json.dumps(payload, indent=2), encoding="utf-8"
    )
    print(json.dumps(payload, indent=2))


if __name__ == "__main__":
    main()
