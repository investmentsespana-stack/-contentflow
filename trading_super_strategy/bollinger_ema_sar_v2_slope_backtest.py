"""Discovery-only V2: same Bollinger/EMA/SAR setup as V1, but with a causal
ATR-normalized EMA20 net-slope filter. LONG and SHORT are evaluated separately.
"""
from __future__ import annotations

import json
import os
from collections import Counter
from pathlib import Path

import numpy as np
import pandas as pd

import bollinger_ema_sar_v1_backtest as v1

OUT = Path("bollinger_ema_sar_v2_slope_output")
SLOPE_THRESHOLD = 0.05


def enrich_v2(g: pd.DataFrame) -> pd.DataFrame:
    g = v1.enrich(g)
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
    g["ema20_slope_norm"] = (g["ema20"] - g["ema20"].shift(3)) / g["atr14"].replace(0.0, np.nan)
    return g


def signal_masks_v2(g: pd.DataFrame):
    rl, rs, el, es = v1.candle_patterns(g)
    prev_struct_low = g["confirmed_swing_low"].shift(1)
    prev_struct_high = g["confirmed_swing_high"].shift(1)

    long_parts = {
        "structure_sweep_reclaim": (g["low"].shift(1) < prev_struct_low) & (g["close"] > prev_struct_low),
        "bollinger_touch": (g["low"].shift(1) <= g["bb_lower"].shift(1)) | (g["low"] <= g["bb_lower"]),
        "ema20_slope_non_sideways": g["ema20_slope_norm"] >= SLOPE_THRESHOLD,
        "ema3_9_cross": (g["ema3"].shift(1) <= g["ema9"].shift(1)) & (g["ema3"] > g["ema9"]),
        "close_vs_ema9": g["close"] > g["ema9"],
        "psar": g["psar"] < g["low"],
        "signal_shape": g["low"] > g["low"].shift(1),
        "pattern": rl | el,
    }
    short_parts = {
        "structure_sweep_reclaim": (g["high"].shift(1) > prev_struct_high) & (g["close"] < prev_struct_high),
        "bollinger_touch": (g["high"].shift(1) >= g["bb_upper"].shift(1)) | (g["high"] >= g["bb_upper"]),
        "ema20_slope_non_sideways": g["ema20_slope_norm"] <= -SLOPE_THRESHOLD,
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


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    if symbol not in v1.SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")

    OUT.mkdir(exist_ok=True)
    g = enrich_v2(v1.load_market(symbol))
    long_parts, short_parts, long_mask, short_mask, pats = signal_masks_v2(g)

    trades = []
    i = 205
    while i < len(g) - 1:
        long_ok = bool(long_mask.iloc[i])
        short_ok = bool(short_mask.iloc[i])
        if long_ok == short_ok:
            i += 1
            continue
        direction = 1 if long_ok else -1
        result = v1.run_trade(g, i, direction)
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
            "pattern": v1.pattern_name(i, direction, pats),
            "signal_open": float(row["open"]),
            "signal_high": float(row["high"]),
            "signal_low": float(row["low"]),
            "signal_close": float(row["close"]),
            "prior_low": float(prev["low"]),
            "prior_high": float(prev["high"]),
            "bb_width_signal": float(row["bb_width"]),
            "atr14_signal": float(row["atr14"]),
            "ema20_slope_norm": float(row["ema20_slope_norm"]),
            "ema3": float(row["ema3"]),
            "ema9": float(row["ema9"]),
            "ema20": float(row["ema20"]),
            "ema50": float(row["ema50"]),
            "ema200": float(row["ema200"]),
            "close_above_ema50": bool(row["close"] > row["ema50"]),
            "close_above_ema200": bool(row["close"] > row["ema200"]),
            "ema50_above_ema200": bool(row["ema50"] > row["ema200"]),
            **{k: val for k, val in result.items() if not k.endswith("_i")},
        }
        trades.append(rec)
        i = int(result["exit_i"]) + 1

    tdf = pd.DataFrame(trades)
    tdf.to_csv(OUT / f"{symbol.replace('.', '_')}_trades.csv", index=False)

    summary = {
        "strategy": "bollinger_ema_sar_v2_slope",
        "symbol": symbol,
        "window": [str(v1.START), str(v1.END)],
        "timeframe": "1m",
        "live_money": False,
        "slope_rule": {
            "formula": "(EMA20[t]-EMA20[t-3])/ATR14[t]",
            "long_min": SLOPE_THRESHOLD,
            "short_max": -SLOPE_THRESHOLD,
            "sideways": f"NO_TRADE when abs(slope_norm) < {SLOPE_THRESHOLD}",
        },
        "exit_rule": "40% Bollinger bandwidth target OR max 3 bars; stop remains active; stop-first on same-bar ambiguity",
        "overall": v1.metrics(trades),
        "by_direction": {},
        "by_session": {},
        "by_pattern": {},
        "exit_reasons": dict(Counter(r["exit_reason"] for r in trades)),
        "filter_funnel": {
            "LONG": v1.cumulative_funnel(long_parts),
            "SHORT": v1.cumulative_funnel(short_parts),
        },
    }

    for direction in ("LONG", "SHORT"):
        subset = [r for r in trades if r["direction"] == direction]
        summary["by_direction"][direction] = v1.metrics(subset)
    for sess in sorted({r["session"] for r in trades}):
        summary["by_session"][sess] = v1.metrics([r for r in trades if r["session"] == sess])
    for pat in sorted({r["pattern"] for r in trades}):
        summary["by_pattern"][pat] = v1.metrics([r for r in trades if r["pattern"] == pat])

    (OUT / f"{symbol.replace('.', '_')}_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
