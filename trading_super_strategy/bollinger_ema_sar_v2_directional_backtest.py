"""Directional V2 discovery test for the preregistered 1m Bollinger/EMA/SAR setup.

Only one rule changes from V1: the market-regime gate. The strict three-step
monotonic EMA20 requirement is replaced by a causal 5-bar EMA20 slope normalized
by ATR14. LONG and SHORT are run as separate experiments.
"""
from __future__ import annotations

import json
import os
from collections import Counter
from pathlib import Path

import numpy as np
import pandas as pd

import bollinger_ema_sar_v1_backtest as base

OUT = Path("bollinger_ema_sar_v2_directional_output")
SLOPE_THRESHOLD = 0.10


def enrich_v2(g: pd.DataFrame) -> pd.DataFrame:
    g = base.enrich(g)
    prev_close = g["close"].astype(float).shift(1)
    tr = pd.concat(
        [
            g["high"].astype(float) - g["low"].astype(float),
            (g["high"].astype(float) - prev_close).abs(),
            (g["low"].astype(float) - prev_close).abs(),
        ],
        axis=1,
    ).max(axis=1)
    g["atr14"] = tr.rolling(14, min_periods=14).mean()
    g["ema20_slope5_atr"] = (g["ema20"] - g["ema20"].shift(5)) / g["atr14"].replace(0.0, np.nan)
    return g


def signal_parts(g: pd.DataFrame, direction: str):
    rl, rs, el, es = base.candle_patterns(g)
    prev_struct_low = g["confirmed_swing_low"].shift(1)
    prev_struct_high = g["confirmed_swing_high"].shift(1)

    if direction == "LONG":
        parts = {
            "structure_sweep_reclaim": (g["low"].shift(1) < prev_struct_low) & (g["close"] > prev_struct_low),
            "bollinger_touch": (g["low"].shift(1) <= g["bb_lower"].shift(1)) | (g["low"] <= g["bb_lower"]),
            "ema20_directional_slope": g["ema20_slope5_atr"] >= SLOPE_THRESHOLD,
            "ema3_9_cross": (g["ema3"].shift(1) <= g["ema9"].shift(1)) & (g["ema3"] > g["ema9"]),
            "close_vs_ema9": g["close"] > g["ema9"],
            "psar": g["psar"] < g["low"],
            "signal_shape": g["low"] > g["low"].shift(1),
            "pattern": rl | el,
        }
        pats = (rl, rs, el, es)
    else:
        parts = {
            "structure_sweep_reclaim": (g["high"].shift(1) > prev_struct_high) & (g["close"] < prev_struct_high),
            "bollinger_touch": (g["high"].shift(1) >= g["bb_upper"].shift(1)) | (g["high"] >= g["bb_upper"]),
            "ema20_directional_slope": g["ema20_slope5_atr"] <= -SLOPE_THRESHOLD,
            "ema3_9_cross": (g["ema3"].shift(1) >= g["ema9"].shift(1)) & (g["ema3"] < g["ema9"]),
            "close_vs_ema9": g["close"] < g["ema9"],
            "psar": g["psar"] > g["high"],
            "signal_shape": g["high"] < g["high"].shift(1),
            "pattern": rs | es,
        }
        pats = (rl, rs, el, es)

    mask = pd.Series(True, index=g.index)
    for v in parts.values():
        mask &= v.fillna(False)
    return parts, mask, pats


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    direction = os.getenv("BES_DIRECTION", "LONG").strip().upper()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")
    if direction not in {"LONG", "SHORT"}:
        raise SystemExit(f"Unsupported BES_DIRECTION={direction}")

    OUT.mkdir(exist_ok=True)
    g = enrich_v2(base.load_market(symbol))
    parts, mask, pats = signal_parts(g, direction)
    sign = 1 if direction == "LONG" else -1

    trades = []
    i = 205
    while i < len(g) - 1:
        if not bool(mask.iloc[i]):
            i += 1
            continue
        result = base.run_trade(g, i, sign)
        if result is None:
            i += 1
            continue
        row = g.iloc[i]
        prev = g.iloc[i - 1]
        rec = {
            "symbol": symbol,
            "direction": direction,
            "signal_time_et": str(row["local_time"]),
            "entry_time_et": str(g.iloc[result["entry_i"]]["local_time"]),
            "exit_time_et": str(g.iloc[result["exit_i"]]["local_time"]),
            "session": str(row["session"]),
            "pattern": base.pattern_name(i, sign, pats),
            "signal_open": float(row["open"]),
            "signal_high": float(row["high"]),
            "signal_low": float(row["low"]),
            "signal_close": float(row["close"]),
            "prior_low": float(prev["low"]),
            "prior_high": float(prev["high"]),
            "bb_width_signal": float(row["bb_width"]),
            "atr14": float(row["atr14"]),
            "ema20_slope5_atr": float(row["ema20_slope5_atr"]),
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
        i = int(result["exit_i"]) + 1

    stem = f"{symbol.replace('.', '_')}_{direction.lower()}"
    pd.DataFrame(trades).to_csv(OUT / f"{stem}_trades.csv", index=False)
    summary = {
        "strategy": "bollinger_ema_sar_v2_directional_slope",
        "symbol": symbol,
        "direction": direction,
        "window": [str(base.START), str(base.END)],
        "timeframe": "1m",
        "live_money": False,
        "slope_filter": {
            "formula": "(EMA20[t]-EMA20[t-5])/ATR14[t]",
            "threshold": SLOPE_THRESHOLD,
            "rule": ">= +0.10 LONG; <= -0.10 SHORT",
        },
        "exit_rule": "40% Bollinger bandwidth target OR max 3 bars; stop remains active; stop-first on same-bar ambiguity",
        "overall": base.metrics(trades),
        "by_session": {},
        "by_pattern": {},
        "exit_reasons": dict(Counter(r["exit_reason"] for r in trades)),
        "filter_funnel": base.cumulative_funnel(parts),
    }
    for sess in sorted({r["session"] for r in trades}):
        summary["by_session"][sess] = base.metrics([r for r in trades if r["session"] == sess])
    for pat in sorted({r["pattern"] for r in trades}):
        summary["by_pattern"][pat] = base.metrics([r for r in trades if r["pattern"] == pat])

    (OUT / f"{stem}_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
