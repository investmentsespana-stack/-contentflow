"""Consolidate Bollinger/EMA/SAR v1.1 slope A/B/C discovery artifacts."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path("bollinger_ema_sar_v1_1_slope_ab_downloads")
OUT = Path("bollinger_ema_sar_v1_1_slope_ab_crossmarket")
MODES = ("monotonic3_baseline", "current_slope", "net3_slope")


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
    frames = []
    for p in ROOT.rglob("*_trades.csv"):
        try:
            df = pd.read_csv(p)
            if not df.empty:
                frames.append(df)
        except pd.errors.EmptyDataError:
            pass
    columns = ["slope_mode","symbol","direction","session","pattern","entry_time_et","net_r","exit_reason"]
    all_df = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame(columns=columns)
    if not all_df.empty:
        all_df = all_df.sort_values(["slope_mode","entry_time_et"]).reset_index(drop=True)
    all_df.to_csv(OUT / "all_trades.csv", index=False)

    result = {
        "strategy": "bollinger_ema_sar_v1_1_slope_ab",
        "discovery_window": ["2025-09-25", "2026-09-11"],
        "comparison": {},
        "decision": "DIAGNOSTIC_DISCOVERY_ONLY_NO_LIVE",
        "selection_warning": "Do not select on PnL alone; sample size and stability must be considered before confirmatory promotion."
    }
    for mode in MODES:
        d = all_df[all_df["slope_mode"] == mode] if not all_df.empty else all_df
        block = {
            "overall": metrics(d),
            "by_symbol": {},
            "by_direction": {},
            "by_session": {},
            "by_pattern": {},
        }
        for sym in sorted(d["symbol"].unique()) if not d.empty else []:
            block["by_symbol"][sym] = metrics(d[d["symbol"] == sym])
        for direction in ("LONG", "SHORT"):
            block["by_direction"][direction] = metrics(d[d["direction"] == direction]) if not d.empty else metrics(d)
        for sess in sorted(d["session"].unique()) if not d.empty else []:
            block["by_session"][sess] = metrics(d[d["session"] == sess])
        for pat in sorted(d["pattern"].unique()) if not d.empty else []:
            block["by_pattern"][pat] = metrics(d[d["pattern"] == pat])
        result["comparison"][mode] = block

    (OUT / "crossmarket_slope_comparison.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
