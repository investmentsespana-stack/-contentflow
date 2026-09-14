"""Discovery-only 5m Bollinger/EMA/SAR backtest.

This version preserves the V2 logic and changes only the active bar timeframe
from 1 minute to 5 minutes. Databento 1m OHLCV is aggregated causally to 5m.
"""
from __future__ import annotations

import json
import os
from collections import Counter
from pathlib import Path

import pandas as pd

import bollinger_ema_sar_v1_backtest as base
import bollinger_ema_sar_v2_backtest as v2

OUT = Path("bollinger_ema_sar_v3_5m_output")


def load_market_5m(symbol: str) -> pd.DataFrame:
    one = base.load_market(symbol).copy()
    idx = pd.DatetimeIndex(one["local_time"])
    one = one.set_index(idx)

    agg = {
        "open": "first",
        "high": "max",
        "low": "min",
        "close": "last",
        "volume": "sum",
    }
    five = one.resample("5min", label="left", closed="left").agg(agg)
    five = five.dropna(subset=["open", "high", "low", "close"]).copy()
    five["local_time"] = five.index
    five = five.reset_index(drop=True)
    return five


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")

    OUT.mkdir(exist_ok=True)
    g = base.enrich(load_market_5m(symbol))
    long_parts, short_parts, long_mask, short_mask, pats = v2.signal_masks_v2(g)

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
        delta5 = float(row["ema20"] - g.iloc[i - v2.SLOPE_LOOKBACK]["ema20"])
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
            **{k: val for k, val in result.items() if not k.endswith("_i")},
        }
        trades.append(rec)
        i = int(result["exit_i"]) + 1

    tdf = pd.DataFrame(trades)
    tdf.to_csv(OUT / f"{symbol.replace('.', '_')}_trades.csv", index=False)

    summary = {
        "strategy": "bollinger_ema_sar_v3_5m",
        "symbol": symbol,
        "window": [str(base.START), str(base.END)],
        "timeframe": "5m",
        "live_money": False,
        "single_change_vs_v2": "1m -> 5m timeframe",
        "slope_filter": {
            "lookback_bars": v2.SLOPE_LOOKBACK,
            "minimum_directional_ema20_move_as_bb_width": v2.SLOPE_BB_FRACTION,
            "sideways": "NO_TRADE",
        },
        "exit_rule": "40% Bollinger bandwidth target OR max 3 x 5m bars (15 minutes); stop remains active; stop-first on same-bar ambiguity",
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
