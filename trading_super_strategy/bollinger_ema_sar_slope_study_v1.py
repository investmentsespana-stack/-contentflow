"""Discovery-only slope study for Bollinger/EMA/SAR V1.

Only the market-slope / sideways filter changes. Every other entry, stop and exit
rule is inherited from bollinger_ema_sar_v1_backtest.py. No confirmatory or
sealed-holdout data is used here.
"""
from __future__ import annotations

import json
import math
import os
from collections import Counter
from pathlib import Path

import pandas as pd

import bollinger_ema_sar_v1_backtest as base

OUT = Path("bollinger_ema_sar_slope_study_v1_output")
MODES = ("strict3_baseline", "directional3", "bbnorm_2p5", "bbnorm_5")


def combine(parts: dict[str, pd.Series]) -> pd.Series:
    out = pd.Series(True, index=next(iter(parts.values())).index)
    for mask in parts.values():
        out &= mask.fillna(False)
    return out


def slope_masks(g: pd.DataFrame, mode: str) -> tuple[pd.Series, pd.Series]:
    ema20 = g["ema20"].astype(float)
    disp3 = ema20 - ema20.shift(3)
    width = g["bb_width"].astype(float)

    if mode == "strict3_baseline":
        long_slope = (
            (ema20 > ema20.shift(1))
            & (ema20.shift(1) > ema20.shift(2))
            & (ema20.shift(2) > ema20.shift(3))
        )
        short_slope = (
            (ema20 < ema20.shift(1))
            & (ema20.shift(1) < ema20.shift(2))
            & (ema20.shift(2) < ema20.shift(3))
        )
        return long_slope.fillna(False), short_slope.fillna(False)

    long_slope = disp3 > 0
    short_slope = disp3 < 0
    if mode == "directional3":
        return long_slope.fillna(False), short_slope.fillna(False)

    threshold = 0.025 if mode == "bbnorm_2p5" else 0.05
    meaningful = disp3.abs() >= threshold * width
    return (long_slope & meaningful).fillna(False), (short_slope & meaningful).fillna(False)


def masks_for_mode(g: pd.DataFrame, mode: str):
    long_parts, short_parts, _, _, pats = base.signal_masks(g)
    long_slope, short_slope = slope_masks(g, mode)
    # Replace only the existing slope condition; insertion order remains unchanged,
    # which keeps the funnel directly comparable to V1.
    long_parts["ema20_slope"] = long_slope
    short_parts["ema20_slope"] = short_slope
    return long_parts, short_parts, combine(long_parts), combine(short_parts), pats


def simulate_mode(g: pd.DataFrame, symbol: str, mode: str):
    long_parts, short_parts, long_mask, short_mask, pats = masks_for_mode(g, mode)
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
        disp3 = float(row["ema20"] - g.iloc[i - 3]["ema20"])
        width = float(row["bb_width"])
        slope_norm = abs(disp3) / width if math.isfinite(width) and width > 0 else float("nan")
        rec = {
            "slope_mode": mode,
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
            "bb_width_signal": width,
            "ema20_disp_3bars": disp3,
            "ema20_disp_abs_over_bb_width": slope_norm,
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

    funnel = {
        "LONG": base.cumulative_funnel(long_parts),
        "SHORT": base.cumulative_funnel(short_parts),
    }
    return trades, funnel


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")

    OUT.mkdir(exist_ok=True)
    g = base.enrich(base.load_market(symbol))

    all_trades = []
    summary = {
        "study": "bollinger_ema_sar_slope_study_v1",
        "symbol": symbol,
        "window": [str(base.START), str(base.END)],
        "timeframe": "1m",
        "live_money": False,
        "fixed_rule": "Only slope/sideways definition varies; all other BES V1 rules are fixed.",
        "modes": {},
    }

    for mode in MODES:
        trades, funnel = simulate_mode(g, symbol, mode)
        all_trades.extend(trades)
        mode_summary = {
            "overall": base.metrics(trades),
            "by_direction": {},
            "by_session": {},
            "by_pattern": {},
            "exit_reasons": dict(Counter(r["exit_reason"] for r in trades)),
            "filter_funnel": funnel,
        }
        for direction in ("LONG", "SHORT"):
            mode_summary["by_direction"][direction] = base.metrics(
                [r for r in trades if r["direction"] == direction]
            )
        for sess in sorted({r["session"] for r in trades}):
            mode_summary["by_session"][sess] = base.metrics(
                [r for r in trades if r["session"] == sess]
            )
        for pat in sorted({r["pattern"] for r in trades}):
            mode_summary["by_pattern"][pat] = base.metrics(
                [r for r in trades if r["pattern"] == pat]
            )
        summary["modes"][mode] = mode_summary

    cols = [
        "slope_mode", "symbol", "direction", "signal_time_et", "entry_time_et",
        "exit_time_et", "session", "pattern", "signal_open", "signal_high",
        "signal_low", "signal_close", "prior_low", "prior_high", "bb_width_signal",
        "ema20_disp_3bars", "ema20_disp_abs_over_bb_width", "ema3", "ema9",
        "ema20", "ema50", "ema200", "close_above_ema50", "close_above_ema200",
        "ema50_above_ema200", "entry", "stop", "target", "exit", "exit_reason",
        "risk_points", "pnl_points", "gross_r", "net_r", "bars_held"
    ]
    pd.DataFrame(all_trades, columns=cols).to_csv(
        OUT / f"{symbol.replace('.', '_')}_slope_study_trades.csv", index=False
    )
    (OUT / f"{symbol.replace('.', '_')}_slope_study_summary.json").write_text(
        json.dumps(summary, indent=2), encoding="utf-8"
    )
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
