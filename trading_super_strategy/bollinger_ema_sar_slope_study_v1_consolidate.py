"""Consolidate per-market Bollinger/EMA/SAR slope-study artifacts."""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path("bollinger_ema_sar_slope_study_v1_downloads")
OUT = Path("bollinger_ema_sar_slope_study_v1_crossmarket")
MODES = ("strict3_baseline", "directional3", "bbnorm_2p5", "bbnorm_5")


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
        return {
            "trades": 0,
            "net_total_r": 0.0,
            "net_expectancy_r": 0.0,
            "net_profit_factor": 0.0,
            "net_win_rate": 0.0,
            "net_max_drawdown_r": 0.0,
            "target_hit_rate": 0.0,
            "stop_hit_rate": 0.0,
            "time_exit_rate": 0.0,
        }
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
    files = list(ROOT.rglob("*_slope_study_trades.csv"))
    frames = []
    for p in files:
        try:
            df = pd.read_csv(p)
            if not df.empty:
                frames.append(df)
        except pd.errors.EmptyDataError:
            pass

    cols = ["slope_mode", "symbol", "direction", "session", "pattern", "entry_time_et", "net_r", "exit_reason"]
    all_df = pd.concat(frames, ignore_index=True) if frames else pd.DataFrame(columns=cols)
    if not all_df.empty:
        all_df = all_df.sort_values(["slope_mode", "entry_time_et"]).reset_index(drop=True)
    all_df.to_csv(OUT / "all_slope_study_trades.csv", index=False)

    result = {
        "study": "bollinger_ema_sar_slope_study_v1",
        "discovery_window": ["2025-09-25", "2026-09-11"],
        "live_money": False,
        "decision": "DISCOVERY_ONLY_NO_LIVE",
        "modes": {},
    }

    for mode in MODES:
        mdf = all_df[all_df["slope_mode"] == mode] if not all_df.empty else all_df.copy()
        entry = {
            "overall": metrics(mdf),
            "by_direction": {},
            "by_symbol": {},
            "by_symbol_direction": {},
            "by_session": {},
            "by_pattern": {},
        }
        for direction in ("LONG", "SHORT"):
            entry["by_direction"][direction] = metrics(mdf[mdf["direction"] == direction])
        for sym in sorted(mdf["symbol"].unique()) if not mdf.empty else []:
            entry["by_symbol"][sym] = metrics(mdf[mdf["symbol"] == sym])
            for direction in ("LONG", "SHORT"):
                entry["by_symbol_direction"][f"{sym}|{direction}"] = metrics(
                    mdf[(mdf["symbol"] == sym) & (mdf["direction"] == direction)]
                )
        for sess in sorted(mdf["session"].unique()) if not mdf.empty else []:
            entry["by_session"][sess] = metrics(mdf[mdf["session"] == sess])
        for pat in sorted(mdf["pattern"].unique()) if not mdf.empty else []:
            entry["by_pattern"][pat] = metrics(mdf[mdf["pattern"] == pat])
        result["modes"][mode] = entry

    (OUT / "crossmarket_slope_study_summary.json").write_text(
        json.dumps(result, indent=2), encoding="utf-8"
    )
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
