"""Consolidate V2 LONG-only and SHORT-only Bollinger/EMA/SAR discovery results."""
from __future__ import annotations

import json
from pathlib import Path

import pandas as pd

import bollinger_ema_sar_v1_backtest as base

ROOT = Path("bollinger_ema_sar_v2_directional_downloads")
OUT = Path("bollinger_ema_sar_v2_directional_crossmarket")


def read_trades():
    frames = []
    for p in ROOT.rglob("*_trades.csv"):
        try:
            df = pd.read_csv(p)
        except pd.errors.EmptyDataError:
            continue
        if not df.empty:
            frames.append(df)
    if not frames:
        return pd.DataFrame()
    return pd.concat(frames, ignore_index=True).sort_values("entry_time_et").reset_index(drop=True)


def m(df: pd.DataFrame):
    return base.metrics(df.to_dict("records")) if not df.empty else base.metrics([])


def main():
    OUT.mkdir(exist_ok=True)
    all_df = read_trades()
    if not all_df.empty:
        all_df.to_csv(OUT / "all_directional_trades.csv", index=False)

    result = {
        "strategy": "bollinger_ema_sar_v2_directional_slope",
        "window": ["2025-09-25", "2026-09-11"],
        "slope_rule": "EMA20 5-bar slope / ATR14; LONG >= +0.10; SHORT <= -0.10",
        "direction_isolation": True,
        "LONG": {"overall": base.metrics([]), "by_symbol": {}, "by_pattern": {}, "by_session": {}},
        "SHORT": {"overall": base.metrics([]), "by_symbol": {}, "by_pattern": {}, "by_session": {}},
        "decision": "DISCOVERY_ONLY_NO_LIVE",
    }

    for direction in ("LONG", "SHORT"):
        ddf = all_df[all_df["direction"] == direction] if not all_df.empty else pd.DataFrame()
        result[direction]["overall"] = m(ddf) if not ddf.empty else base.metrics([])
        if not ddf.empty:
            for sym in sorted(ddf["symbol"].unique()):
                result[direction]["by_symbol"][sym] = m(ddf[ddf["symbol"] == sym])
            for pat in sorted(ddf["pattern"].unique()):
                result[direction]["by_pattern"][pat] = m(ddf[ddf["pattern"] == pat])
            for sess in sorted(ddf["session"].unique()):
                result[direction]["by_session"][sess] = m(ddf[ddf["session"] == sess])

    (OUT / "directional_summary.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
