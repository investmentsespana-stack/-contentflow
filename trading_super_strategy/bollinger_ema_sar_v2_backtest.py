"""Discovery-only V2: identical to V1 except the EMA20 trend filter.

V2 replaces three consecutive monotonic EMA20 transitions with a causal 5-bar
net slope. A signal is non-lateral only when the EMA20 changes at least 5% of
the contemporaneous Bollinger bandwidth in the trade direction.
"""
from __future__ import annotations

import json
import os
from collections import Counter
from pathlib import Path

import pandas as pd

import bollinger_ema_sar_v1_backtest as base

OUT = Path("bollinger_ema_sar_v2_output")
SLOPE_LOOKBACK = 5
SLOPE_BB_FRACTION = 0.05


def signal_masks_v2(g: pd.DataFrame):
    rl, rs, el, es = base.candle_patterns(g)
    prev_struct_low = g["confirmed_swing_low"].shift(1)
    prev_struct_high = g["confirmed_swing_high"].shift(1)

    ema20_delta = g["ema20"] - g["ema20"].shift(SLOPE_LOOKBACK)
    min_move = SLOPE_BB_FRACTION * g["bb_width"]

    long_parts = {
        "structure_sweep_reclaim": (g["low"].shift(1) < prev_struct_low) & (g["close"] > prev_struct_low),
        "bollinger_touch": (g["low"].shift(1) <= g["bb_lower"].shift(1)) | (g["low"] <= g["bb_lower"]),
        "ema20_nonlateral_slope": ema20_delta >= min_move,
        "ema3_9_cross": (g["ema3"].shift(1) <= g["ema9"].shift(1)) & (g["ema3"] > g["ema9"]),
        "close_vs_ema9": g["close"] > g["ema9"],
        "psar": g["psar"] < g["low"],
        "signal_shape": g["low"] > g["low"].shift(1),
        "pattern": rl | el,
    }
    short_parts = {
        "structure_sweep_reclaim": (g["high"].shift(1) > prev_struct_high) & (g["close"] < prev_struct_high),
        "bollinger_touch": (g["high"].shift(1) >= g["bb_upper"].shift(1)) | (g["high"] >= g["bb_upper"]),
        "ema20_nonlateral_slope": (-ema20_delta) >= min_move,
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


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")

    OUT.mkdir(exist_ok=True)
    g = base.enrich(base.load_market(symbol))
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
        result = base.run_trade(g, i, direction)
        if result is None:
            i += 1
            continue

        row = g.iloc[i]
        prev = g.iloc[i - 1]
        delta5 = float(row["ema20"] - g.iloc[i - SLOPE_LOOKBACK]["ema20"])
        slope_ratio = delta5 / float(row["bb_width"]) if float(row["bb_width"]) > 0 else 0.0
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
            "ema20_delta_5": delta5,
            "ema20_slope_bb_ratio": slope_ratio,
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
        "strategy": "bollinger_ema_sar_v2",
        "symbol": symbol,
        "window": [str(base.START), str(base.END)],
        "timeframe": "1m",
        "live_money": False,
        "single_change_vs_v1": {
            "slope_lookback_bars": SLOPE_LOOKBACK,
            "minimum_directional_ema20_move_as_bb_width": SLOPE_BB_FRACTION,
            "sideways": "NO_TRADE",
        },
        "exit_rule": "40% Bollinger bandwidth target OR max 3 bars; stop remains active; stop-first on same-bar ambiguity",
        "overall": base.metrics(trades),
        "by_direction": {},
        "by_session": {},
        "by_pattern": {},
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

    (OUT / f"{symbol.replace('.', '_')}_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
