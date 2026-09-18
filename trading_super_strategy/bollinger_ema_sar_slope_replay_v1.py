"""Replay the preregistered Bollinger/EMA/SAR slope study from frozen evidence.

This recovery path exists because the live Databento account is currently locked.
It uses the successful discovery artifact from run 34798849139 and does not request
new market data, touch confirmatory data, or touch the sealed holdout.
"""
from __future__ import annotations

import json
from pathlib import Path

import numpy as np
import pandas as pd

SOURCE = Path("frozen_slope_source/all_trades.csv")
OUT = Path("bollinger_ema_sar_slope_replay_v1_output")


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


def metrics(df: pd.DataFrame) -> dict:
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


def summarize(df: pd.DataFrame) -> dict:
    out = {
        "overall": metrics(df),
        "by_symbol": {},
        "by_direction": {},
        "by_session": {},
        "by_pattern": {},
    }
    for sym in sorted(df["symbol"].unique()) if not df.empty else []:
        out["by_symbol"][sym] = metrics(df[df["symbol"] == sym])
    for direction in ("LONG", "SHORT"):
        out["by_direction"][direction] = metrics(df[df["direction"] == direction])
    for sess in sorted(df["session"].unique()) if not df.empty else []:
        out["by_session"][sess] = metrics(df[df["session"] == sess])
    for pat in sorted(df["pattern"].unique()) if not df.empty else []:
        out["by_pattern"][pat] = metrics(df[df["pattern"] == pat])
    return out


def main() -> None:
    if not SOURCE.exists():
        raise SystemExit(f"Missing frozen source: {SOURCE}")

    df = pd.read_csv(SOURCE)
    required = {
        "slope_mode", "ema20_delta3", "bb_width_signal", "net_r", "symbol",
        "direction", "session", "pattern", "exit_reason",
    }
    missing = sorted(required - set(df.columns))
    if missing:
        raise SystemExit(f"Frozen source missing columns: {missing}")

    df["slope_ratio3_bb"] = (
        df["ema20_delta3"].astype(float).abs()
        / df["bb_width_signal"].astype(float).abs().replace(0.0, np.nan)
    )

    strict3 = df[df["slope_mode"] == "monotonic3_baseline"].copy()
    directional3 = df[df["slope_mode"] == "net3_slope"].copy()
    bbnorm_2p5 = directional3[directional3["slope_ratio3_bb"] >= 0.025].copy()
    bbnorm_5 = directional3[directional3["slope_ratio3_bb"] >= 0.05].copy()

    variants = {
        "strict3_baseline": strict3,
        "directional3": directional3,
        "bbnorm_2p5": bbnorm_2p5,
        "bbnorm_5": bbnorm_5,
    }

    OUT.mkdir(exist_ok=True)
    summary = {
        "study": "bollinger_ema_sar_slope_study_v1_replay",
        "source_run_id": 34798849139,
        "source_artifact": "bes-v1-1-slope-crossmarket",
        "source_artifact_digest": "sha256:020874e74afb123677f39c345ab66401a9e5b63a2a07905d91d91e2120cb0ced",
        "discovery_window": ["2025-09-25", "2026-09-11"],
        "data_governance": {
            "new_market_data_requested": False,
            "confirmatory_2022_2025": "UNTOUCHED",
            "sealed_holdout_2020_2022": "UNTOUCHED",
            "live_money": False,
        },
        "variants": {},
        "note": "All non-slope rules are inherited from the frozen successful slope A/B discovery source.",
    }

    for name, work in variants.items():
        summary["variants"][name] = summarize(work)
        work.to_csv(OUT / f"{name}_trades.csv", index=False)

    (OUT / "slope_replay_summary.json").write_text(
        json.dumps(summary, indent=2, allow_nan=True),
        encoding="utf-8",
    )
    print(json.dumps(summary, indent=2, allow_nan=True))


if __name__ == "__main__":
    main()
