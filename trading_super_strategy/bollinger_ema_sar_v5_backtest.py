"""Discovery-only V5: wait for the proper Bollinger-band correction after EMA3/9 state.

LONG requires the signal candle itself at the lower Bollinger band and EMA3>EMA9.
SHORT requires the signal candle itself at the upper Bollinger band and EMA3<EMA9.
The V2 fixed EMA20 non-lateral slope filter is retained. Exit remains 40% BB width
or a maximum of three 1-minute bars. Confirmatory/holdout data are untouched.
"""
from __future__ import annotations

import json
import os
from collections import Counter
from pathlib import Path

import numpy as np
import pandas as pd

import bollinger_ema_sar_v1_backtest as base

OUT = Path("bollinger_ema_sar_v5_output")
SLOPE_LOOKBACK = 5
SLOPE_BB_FRACTION = 0.05


def cross_ages(g: pd.DataFrame):
    bull = (g["ema3"].shift(1) <= g["ema9"].shift(1)) & (g["ema3"] > g["ema9"])
    bear = (g["ema3"].shift(1) >= g["ema9"].shift(1)) & (g["ema3"] < g["ema9"])
    idx = pd.Series(np.arange(len(g), dtype=float), index=g.index)
    last_bull = idx.where(bull).ffill()
    last_bear = idx.where(bear).ffill()
    return (idx - last_bull), (idx - last_bear), bull.fillna(False), bear.fillna(False)


def signal_masks_v5(g: pd.DataFrame):
    rl, rs, el, es = base.candle_patterns(g)
    prev_struct_low = g["confirmed_swing_low"].shift(1)
    prev_struct_high = g["confirmed_swing_high"].shift(1)

    ema20_delta = g["ema20"] - g["ema20"].shift(SLOPE_LOOKBACK)
    min_move = SLOPE_BB_FRACTION * g["bb_width"]
    bull_age, bear_age, bull_cross, bear_cross = cross_ages(g)

    long_parts = {
        "structure_sweep_reclaim": (g["low"].shift(1) < prev_struct_low) & (g["close"] > prev_struct_low),
        "signal_at_lower_bollinger": g["low"] <= g["bb_lower"],
        "ema20_nonlateral_slope": ema20_delta >= min_move,
        "ema3_9_bull_state": g["ema3"] > g["ema9"],
        "close_vs_ema9": g["close"] > g["ema9"],
        "psar": g["psar"] < g["low"],
        "signal_shape": g["low"] > g["low"].shift(1),
        "pattern": rl | el,
    }
    short_parts = {
        "structure_sweep_reclaim": (g["high"].shift(1) > prev_struct_high) & (g["close"] < prev_struct_high),
        "signal_at_upper_bollinger": g["high"] >= g["bb_upper"],
        "ema20_nonlateral_slope": (-ema20_delta) >= min_move,
        "ema3_9_bear_state": g["ema3"] < g["ema9"],
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

    diagnostics = {
        "bull_cross_age": bull_age,
        "bear_cross_age": bear_age,
        "bull_cross_on_signal": bull_cross,
        "bear_cross_on_signal": bear_cross,
    }
    return long_parts, short_parts, combine(long_parts), combine(short_parts), (rl, rs, el, es), diagnostics


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")

    OUT.mkdir(exist_ok=True)
    g = base.enrich(base.load_market(symbol))
    long_parts, short_parts, long_mask, short_mask, pats, diag = signal_masks_v5(g)

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
        age_series = diag["bull_cross_age"] if direction == 1 else diag["bear_cross_age"]
        age_value = age_series.iloc[i]
        cross_age = None if pd.isna(age_value) else int(age_value)
        fresh_cross = bool(diag["bull_cross_on_signal"].iloc[i] if direction == 1 else diag["bear_cross_on_signal"].iloc[i])

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
            "bb_lower": float(row["bb_lower"]),
            "bb_upper": float(row["bb_upper"]),
            "bb_width_signal": float(row["bb_width"]),
            "ema3": float(row["ema3"]),
            "ema9": float(row["ema9"]),
            "ema20": float(row["ema20"]),
            "ema50": float(row["ema50"]),
            "ema200": float(row["ema200"]),
            "ema20_delta_5": delta5,
            "ema20_slope_bb_ratio": slope_ratio,
            "bars_since_matching_ema3_9_cross": cross_age,
            "fresh_ema3_9_cross_on_signal": fresh_cross,
            "close_above_ema50": bool(row["close"] > row["ema50"]),
            "close_above_ema200": bool(row["close"] > row["ema200"]),
            "ema50_above_ema200": bool(row["ema50"] > row["ema200"]),
            **{k: v for k, v in result.items() if not k.endswith("_i")},
        }
        trades.append(rec)
        i = int(result["exit_i"]) + 1

    tdf = pd.DataFrame(trades)
    tdf.to_csv(OUT / f"{symbol.replace('.', '_')}_trades.csv", index=False)

    ages = [r["bars_since_matching_ema3_9_cross"] for r in trades if r["bars_since_matching_ema3_9_cross"] is not None]
    summary = {
        "strategy": "bollinger_ema_sar_v5_band_correction",
        "symbol": symbol,
        "window": [str(base.START), str(base.END)],
        "timeframe": "1m",
        "live_money": False,
        "entry_change": "LONG signal candle must be at lower Bollinger with EMA3>EMA9; SHORT signal candle must be at upper Bollinger with EMA3<EMA9. Cross may precede signal.",
        "non_lateral_filter": "V2 EMA20 5-bar directional move >= 5% of Bollinger width",
        "exit_rule": "40% Bollinger bandwidth target OR max 3 bars; stop active; same-bar stop-first",
        "overall": base.metrics(trades),
        "by_direction": {},
        "by_session": {},
        "by_pattern": {},
        "exit_reasons": dict(Counter(r["exit_reason"] for r in trades)),
        "cross_age": {
            "count": len(ages),
            "median_bars": float(np.median(ages)) if ages else None,
            "mean_bars": float(np.mean(ages)) if ages else None,
            "fresh_cross_on_signal_count": int(sum(r["fresh_ema3_9_cross_on_signal"] for r in trades)),
        },
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
