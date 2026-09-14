"""Discovery-only robustness study for Bollinger/EMA/SAR v1.1.

Only the interpretation of 'market must have slope / sideways = NO_TRADE' is varied.
The core entry setup remains unchanged. Confirmatory and sealed holdout windows are not touched.
"""
from __future__ import annotations

import json
import math
import os
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd

from bollinger_ema_sar_v1_backtest import (
    SYMBOLS,
    START,
    END,
    candle_patterns,
    enrich,
    load_market,
    pattern_name,
    profit_factor,
    max_dd,
)

OUT = Path("bollinger_ema_sar_v1_1_robustness_output")
SLOPE_MODES = {
    "NET3_SIGN": 0.00,
    "NET3_2PCT_BB": 0.02,
    "NET3_4PCT_BB": 0.04,
}
TARGETS = [0.30, 0.40, 0.50]
HOLDS = [2, 3, 4]
COSTS = [0.03, 0.045, 0.06]
BASE = (0.40, 3, 0.03)


def core_masks(g: pd.DataFrame, slope_threshold: float):
    rl, rs, el, es = candle_patterns(g)
    prev_struct_low = g["confirmed_swing_low"].shift(1)
    prev_struct_high = g["confirmed_swing_high"].shift(1)
    bb = g["bb_width"].replace(0.0, np.nan)
    slope3 = g["ema20"] - g["ema20"].shift(3)
    norm = slope3.abs() / bb

    long_parts = {
        "structure_sweep_reclaim": (g["low"].shift(1) < prev_struct_low) & (g["close"] > prev_struct_low),
        "bollinger_touch": (g["low"].shift(1) <= g["bb_lower"].shift(1)) | (g["low"] <= g["bb_lower"]),
        "ema20_directional_slope": (slope3 > 0) & (norm >= slope_threshold),
        "ema3_9_cross": (g["ema3"].shift(1) <= g["ema9"].shift(1)) & (g["ema3"] > g["ema9"]),
        "close_vs_ema9": g["close"] > g["ema9"],
        "psar": g["psar"] < g["low"],
        "signal_shape": g["low"] > g["low"].shift(1),
        "pattern": rl | el,
    }
    short_parts = {
        "structure_sweep_reclaim": (g["high"].shift(1) > prev_struct_high) & (g["close"] < prev_struct_high),
        "bollinger_touch": (g["high"].shift(1) >= g["bb_upper"].shift(1)) | (g["high"] >= g["bb_upper"]),
        "ema20_directional_slope": (slope3 < 0) & (norm >= slope_threshold),
        "ema3_9_cross": (g["ema3"].shift(1) >= g["ema9"].shift(1)) & (g["ema3"] < g["ema9"]),
        "close_vs_ema9": g["close"] < g["ema9"],
        "psar": g["psar"] > g["high"],
        "signal_shape": g["high"] < g["high"].shift(1),
        "pattern": rs | es,
    }

    def combine(parts):
        out = pd.Series(True, index=g.index)
        for m in parts.values():
            out &= m.fillna(False)
        return out

    return long_parts, short_parts, combine(long_parts), combine(short_parts), (rl, rs, el, es), norm


def run_trade(g: pd.DataFrame, signal_i: int, direction: int, target_fraction: float, hold_bars: int, cost_r: float):
    entry_i = signal_i + 1
    if signal_i < 1 or entry_i >= len(g):
        return None
    entry = float(g.at[entry_i, "open"])
    width = float(g.at[signal_i, "bb_width"])
    if not math.isfinite(width) or width <= 0:
        return None
    if direction == 1:
        stop = float(g.at[signal_i - 1, "low"])
        if entry <= stop:
            return None
        risk = entry - stop
        target = entry + target_fraction * width
    else:
        stop = float(g.at[signal_i - 1, "high"])
        if entry >= stop:
            return None
        risk = stop - entry
        target = entry - target_fraction * width
    if risk <= 0:
        return None

    last_i = min(len(g) - 1, entry_i + hold_bars - 1)
    exit_i = last_i
    exit_price = float(g.at[last_i, "close"])
    reason = f"time_{hold_bars}_bars"
    for j in range(entry_i, last_i + 1):
        high = float(g.at[j, "high"])
        low = float(g.at[j, "low"])
        if direction == 1:
            stop_hit, target_hit = low <= stop, high >= target
        else:
            stop_hit, target_hit = high >= stop, low <= target
        if stop_hit:  # conservative same-bar ambiguity
            exit_i, exit_price, reason = j, stop, "stop"
            break
        if target_hit:
            exit_i, exit_price, reason = j, target, f"target_{int(target_fraction*100)}pct_bb"
            break

    gross_r = direction * (exit_price - entry) / risk
    return {
        "entry_i": entry_i,
        "exit_i": exit_i,
        "gross_r": float(gross_r),
        "net_r": float(gross_r - cost_r),
        "exit_reason": reason,
        "entry": entry,
        "stop": stop,
        "target": target,
        "exit": exit_price,
        "risk_points": risk,
        "bars_held": exit_i - entry_i + 1,
    }


def simulate_config(g, long_mask, short_mask, pats, slope_norm, symbol, slope_mode, target, hold, cost):
    rows = []
    i = 205
    while i < len(g) - 1:
        lo = bool(long_mask.iloc[i])
        sh = bool(short_mask.iloc[i])
        if lo == sh:
            i += 1
            continue
        direction = 1 if lo else -1
        r = run_trade(g, i, direction, target, hold, cost)
        if r is None:
            i += 1
            continue
        signal = g.iloc[i]
        rows.append({
            "symbol": symbol,
            "slope_mode": slope_mode,
            "target_fraction": target,
            "hold_bars": hold,
            "cost_r": cost,
            "direction": "LONG" if direction == 1 else "SHORT",
            "signal_time_et": str(signal["local_time"]),
            "entry_time_et": str(g.iloc[r["entry_i"]]["local_time"]),
            "exit_time_et": str(g.iloc[r["exit_i"]]["local_time"]),
            "session": str(signal["session"]),
            "pattern": pattern_name(i, direction, pats),
            "slope_norm_bb": float(slope_norm.iloc[i]) if pd.notna(slope_norm.iloc[i]) else None,
            "bb_width_signal": float(signal["bb_width"]),
            "ema20": float(signal["ema20"]),
            **{k: v for k, v in r.items() if not k.endswith("_i")},
        })
        i = int(r["exit_i"]) + 1
    return rows


def metrics(rows):
    vals = [float(x["net_r"]) for x in rows]
    return {
        "trades": len(rows),
        "net_total_r": float(sum(vals)),
        "net_expectancy_r": float(np.mean(vals)) if vals else 0.0,
        "profit_factor": float(profit_factor(vals)),
        "win_rate": float(sum(x > 0 for x in vals) / len(vals)) if vals else 0.0,
        "max_drawdown_r": float(max_dd(vals)),
    }


def block_bootstrap_p05(rows, reps=500, block=5, seed=260913):
    vals = np.asarray([float(x["net_r"]) for x in rows], dtype=float)
    n = len(vals)
    if n < 10:
        return None
    rng = np.random.default_rng(seed)
    totals = []
    for _ in range(reps):
        sample = []
        while len(sample) < n:
            start = int(rng.integers(0, n))
            for k in range(block):
                sample.append(vals[(start + k) % n])
                if len(sample) >= n:
                    break
        totals.append(float(np.sum(sample)))
    return float(np.quantile(totals, 0.05))


def main():
    symbol = os.getenv("BES_SYMBOL", "ES.v.0").strip()
    if symbol not in SYMBOLS:
        raise SystemExit(f"Unsupported BES_SYMBOL={symbol}")
    OUT.mkdir(exist_ok=True)
    g = enrich(load_market(symbol))

    all_rows = []
    summary = {
        "strategy": "bollinger_ema_sar_v1_1_robustness",
        "symbol": symbol,
        "window": [str(START), str(END)],
        "data_scope": "DISCOVERY_ONLY",
        "live_money": False,
        "slope_modes": {},
    }

    for mode, threshold in SLOPE_MODES.items():
        lp, sp, lm, sm, pats, slope_norm = core_masks(g, threshold)
        mode_rows = []
        for target in TARGETS:
            for hold in HOLDS:
                for cost in COSTS:
                    rows = simulate_config(g, lm, sm, pats, slope_norm, symbol, mode, target, hold, cost)
                    all_rows.extend(rows)
                    mode_rows.extend(rows)
        base_rows = [r for r in mode_rows if (r["target_fraction"], r["hold_bars"], r["cost_r"]) == BASE]
        two_x_rows = [r for r in mode_rows if (r["target_fraction"], r["hold_bars"], r["cost_r"]) == (0.40, 3, 0.06)]
        cfg_metrics = []
        for target in TARGETS:
            for hold in HOLDS:
                for cost in COSTS:
                    rs = [r for r in mode_rows if r["target_fraction"] == target and r["hold_bars"] == hold and r["cost_r"] == cost]
                    m = metrics(rs)
                    m.update({"target_fraction": target, "hold_bars": hold, "cost_r": cost})
                    cfg_metrics.append(m)
        positive_share = float(sum(m["net_expectancy_r"] > 0 for m in cfg_metrics) / len(cfg_metrics))
        summary["slope_modes"][mode] = {
            "threshold_fraction_bb": threshold,
            "base": metrics(base_rows),
            "two_x_cost": metrics(two_x_rows),
            "positive_perturbation_share": positive_share,
            "bootstrap_p05_total_r_base": block_bootstrap_p05(base_rows),
            "configs": cfg_metrics,
            "signal_counts": {"LONG": int(lm.sum()), "SHORT": int(sm.sum())},
        }

    pd.DataFrame(all_rows).to_csv(OUT / f"{symbol.replace('.', '_')}_robustness_trades.csv", index=False)
    (OUT / f"{symbol.replace('.', '_')}_robustness_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
