"""Consolidate per-market Bollinger/EMA/SAR V5 band-correction artifacts."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path("bollinger_ema_sar_v5_downloads")
OUT = Path("bollinger_ema_sar_v5_crossmarket")


def profit_factor(vals):
    gp = sum(x for x in vals if x > 0)
    gl = abs(sum(x for x in vals if x < 0))
    return gp / gl if gl > 0 else (float("inf") if gp > 0 else 0.0)


def max_dd(vals):
    eq = peak = dd = 0.0
    for x in vals:
        eq += float(x)
        peak = max(peak, eq)
        dd = max(dd, peak - eq)
    return dd


def metrics(df):
    if df.empty:
        return {"trades":0,"net_total_r":0.0,"net_expectancy_r":0.0,"net_profit_factor":0.0,"net_win_rate":0.0,"net_max_drawdown_r":0.0,"target_hit_rate":0.0,"stop_hit_rate":0.0,"time_exit_rate":0.0}
    vals = df["net_r"].astype(float).tolist()
    return {
        "trades": int(len(df)),
        "net_total_r": float(sum(vals)),
        "net_expectancy_r": float(np.mean(vals)),
        "net_profit_factor": float(profit_factor(vals)),
        "net_win_rate": float(sum(x > 0 for x in vals) / len(vals)),
        "net_max_drawdown_r": float(max_dd(vals)),
        "target_hit_rate": float((df["exit_reason"] == "target_40pct_bb").mean()),
        "stop_hit_rate": float((df["exit_reason"] == "stop").mean()),
        "time_exit_rate": float((df["exit_reason"] == "time_3_bars").mean()),
    }


def main():
    OUT.mkdir(exist_ok=True)
    files = list(ROOT.rglob("*_trades.csv"))
    frames = []
    for p in files:
        try:
            df = pd.read_csv(p)
            if not df.empty:
                frames.append(df)
        except pd.errors.EmptyDataError:
            pass

    cols = ["symbol","direction","session","pattern","net_r","exit_reason","entry_time_et","bars_since_matching_ema3_9_cross","fresh_ema3_9_cross_on_signal"]
    all_df = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame(columns=cols)
    if not all_df.empty:
        all_df = all_df.sort_values("entry_time_et").reset_index(drop=True)
    all_df.to_csv(OUT / "all_trades.csv", index=False)

    result = {
        "strategy": "bollinger_ema_sar_v5_band_correction",
        "discovery_window": ["2025-09-25", "2026-09-11"],
        "rule": "LONG only at lower Bollinger with bullish EMA3/9 state; SHORT only at upper Bollinger with bearish EMA3/9 state; V2 EMA20 non-lateral slope retained; 40% BB / max-3-bar exit retained.",
        "overall": metrics(all_df),
        "by_symbol": {},
        "by_direction": {},
        "by_symbol_direction": {},
        "by_session": {},
        "by_pattern": {},
        "cross_age": {},
        "decision": "DISCOVERY_ONLY_NO_LIVE"
    }

    if not all_df.empty:
        for sym in sorted(all_df["symbol"].unique()):
            result["by_symbol"][sym] = metrics(all_df[all_df["symbol"] == sym])
            for direction in ("LONG", "SHORT"):
                result["by_symbol_direction"][f"{sym}|{direction}"] = metrics(all_df[(all_df["symbol"] == sym) & (all_df["direction"] == direction)])
        for sess in sorted(all_df["session"].unique()):
            result["by_session"][sess] = metrics(all_df[all_df["session"] == sess])
        for pat in sorted(all_df["pattern"].unique()):
            result["by_pattern"][pat] = metrics(all_df[all_df["pattern"] == pat])
        ages = pd.to_numeric(all_df["bars_since_matching_ema3_9_cross"], errors="coerce").dropna()
        result["cross_age"] = {
            "count": int(len(ages)),
            "median_bars": float(ages.median()) if len(ages) else None,
            "mean_bars": float(ages.mean()) if len(ages) else None,
            "p90_bars": float(ages.quantile(0.90)) if len(ages) else None,
            "fresh_cross_on_signal_count": int(all_df["fresh_ema3_9_cross_on_signal"].astype(str).str.lower().eq("true").sum())
        }

    for direction in ("LONG", "SHORT"):
        result["by_direction"][direction] = metrics(all_df[all_df["direction"] == direction]) if not all_df.empty else metrics(all_df)

    (OUT / "crossmarket_summary.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
