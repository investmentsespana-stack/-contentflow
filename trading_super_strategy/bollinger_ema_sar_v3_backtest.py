"""Discovery-only V3: same V1 setup, crossover-derived slope filter.

The EMA3/EMA9 crossover is allowed to create the initial slope. V3 removes the
requirement that EMA20 must already be sloping before the signal. EMA9/EMA20 is
recorded diagnostically but does not gate entry or extend the trade.
"""
from __future__ import annotations

import json
import os
from collections import Counter
from pathlib import Path

import pandas as pd

import bollinger_ema_sar_v1_backtest as base

OUT = Path("bollinger_ema_sar_v3_output")


def signal_masks_v3(g: pd.DataFrame):
    rl, rs, el, es = base.candle_patterns(g)
    prev_struct_low = g["confirmed_swing_low"].shift(1)
    prev_struct_high = g["confirmed_swing_high"].shift(1)

    ema3_rising = g["ema3"] > g["ema3"].shift(1)
    ema9_rising = g["ema9"] > g["ema9"].shift(1)
    ema3_falling = g["ema3"] < g["ema3"].shift(1)
    ema9_falling = g["ema9"] < g["ema9"].shift(1)

    long_parts = {
        "structure_sweep_reclaim": (g["low"].shift(1) < prev_struct_low) & (g["close"] > prev_struct_low),
        "bollinger_touch": (g["low"].shift(1) <= g["bb_lower"].shift(1)) | (g["low"] <= g["bb_lower"]),
        "crossover_slope_nonlateral": ema3_rising & ema9_rising,
        "ema3_9_cross": (g["ema3"].shift(1) <= g["ema9"].shift(1)) & (g["ema3"] > g["ema9"]),
        "close_vs_ema9": g["close"] > g["ema9"],
        "psar": g["psar"] < g["low"],
        "signal_shape": g["low"] > g["low"].shift(1),
        "pattern": rl | el,
    }
    short_parts = {
        "structure_sweep_reclaim": (g["high"].shift(1) > prev_struct_high) & (g["close"] < prev_struct_high),
        "bollinger_touch": (g["high"].shift(1) >= g["bb_upper"].shift(1)) | (g["high"] >= g["bb_upper"]),
        "crossover_slope_nonlateral": ema3_falling & ema9_falling,
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


def ema9_20_diagnostics(g: pd.DataFrame, signal_i: int, direction: int, exit_i: int):
    e9 = g["ema9"]
    e20 = g["ema20"]
    if direction == 1:
        aligned = bool(e9.iloc[signal_i] > e20.iloc[signal_i])
        crossed_signal = bool(e9.iloc[signal_i - 1] <= e20.iloc[signal_i - 1] and e9.iloc[signal_i] > e20.iloc[signal_i])
        crossed_during = False
        for j in range(signal_i + 1, min(exit_i, len(g) - 1) + 1):
            if e9.iloc[j - 1] <= e20.iloc[j - 1] and e9.iloc[j] > e20.iloc[j]:
                crossed_during = True
                break
    else:
        aligned = bool(e9.iloc[signal_i] < e20.iloc[signal_i])
        crossed_signal = bool(e9.iloc[signal_i - 1] >= e20.iloc[signal_i - 1] and e9.iloc[signal_i] < e20.iloc[signal_i])
        crossed_during = False
        for j in range(signal_i + 1, min(exit_i, len(g) - 1) + 1):
            if e9.iloc[j - 1] >= e20.iloc[j - 1] and e9.iloc[j] < e20.iloc[j]:
                crossed_during = True
                break
    if crossed_signal:
        phase = "9_20_cross_on_signal"
    elif aligned:
        phase = "9_20_already_aligned"
    elif crossed_during:
        phase = "9_20_cross_during_trade"
    else:
        phase = "3_9_only_no_9_20_confirm"
    return aligned, crossed_signal, crossed_during, phase


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")

    OUT.mkdir(exist_ok=True)
    g = base.enrich(base.load_market(symbol))
    long_parts, short_parts, long_mask, short_mask, pats = signal_masks_v3(g)

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
        aligned, crossed_signal, crossed_during, phase = ema9_20_diagnostics(
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
        "strategy": "bollinger_ema_sar_v3_crossover_slope",
        "symbol": symbol,
        "window": [str(base.START), str(base.END)],
        "timeframe": "1m",
        "live_money": False,
        "single_change_vs_v1": "Replace prior EMA20 monotonic slope gate with same-direction EMA3 and EMA9 slope at the 3/9 cross.",
        "exit_rule": "40% Bollinger bandwidth target OR max 3 bars; stop active; stop-first on same-bar ambiguity",
        "overall": base.metrics(trades),
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
        summary["by_direction"][direction] = base.metrics(subset)
    for sess in sorted({r["session"] for r in trades}):
        summary["by_session"][sess] = base.metrics([r for r in trades if r["session"] == sess])
    for pat in sorted({r["pattern"] for r in trades}):
        summary["by_pattern"][pat] = base.metrics([r for r in trades if r["pattern"] == pat])
    for phase in sorted({r["ema9_20_phase"] for r in trades}):
        summary["by_ema9_20_phase"][phase] = base.metrics([r for r in trades if r["ema9_20_phase"] == phase])

    (OUT / f"{symbol.replace('.', '_')}_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
