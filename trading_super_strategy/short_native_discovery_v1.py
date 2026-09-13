"""Native asymmetric SHORT discovery pilot while StrategyQuant is unavailable.

Discovery only: 2025-09-25..2026-09-11. It does not read 2018-2019, the
2022-2025 confirmatory window, or the sealed 2020-2022 final holdout.
SHORT families are purpose-built and are not inverted LONG templates.
"""
from __future__ import annotations

import json
import math
import os
import random
from collections import defaultdict
from datetime import date, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

import real_strategy_discovery as base
from phase2_historical_search import _trade_outcome_arrays
from phase3_risk_gate_v2 import percentile, sample_moving_blocks
from phase3_risk_gate_v2_resilient import _ResilientHistorical
from robustness_engine import max_drawdown_r

START = date(2025, 9, 25)
END = date(2026, 9, 11)
COST_R = 0.03
COOLDOWN_BARS = 30
MIN_TRADES = 30
MIN_QUARTERS = 3
MIN_POSITIVE_QUARTER_RATE = 0.60
MAX_TOP_POSITIVE_QUARTER_SHARE = 0.65
MC_ITER = 500
MC_BLOCK = 5
RR_GRID = [0.25, 0.4, 0.5, 0.7, 0.75, 1.0, 1.5, 2.0, 3.0, 4.0]
OUT = Path("short_native_discovery_output")

TEMPLATES = [
    {"id":"B1","family":"SHORT_BREAKDOWN_CONTINUATION","kind":"breakdown","neg_votes":1},
    {"id":"B2","family":"SHORT_BREAKDOWN_CONTINUATION","kind":"breakdown","neg_votes":2},
    {"id":"B3","family":"SHORT_BREAKDOWN_CONTINUATION","kind":"breakdown","neg_votes":1,"momentum_max":-1.0},
    {"id":"B4","family":"SHORT_BREAKDOWN_CONTINUATION","kind":"breakdown","neg_votes":2,"range_min":1.2},
    {"id":"B5","family":"SHORT_BREAKDOWN_CONTINUATION","kind":"breakdown","neg_votes":2,"volume_min":1.2},
    {"id":"B6","family":"SHORT_BREAKDOWN_CONTINUATION","kind":"breakdown","neg_votes":2,"vwap_max":-0.5},
    {"id":"A1","family":"SHORT_ACCELERATION","kind":"acceleration","neg_votes":2,"atr_min":1.0,"accel_max":-0.25,"vwap_max":-0.5},
    {"id":"A2","family":"SHORT_ACCELERATION","kind":"acceleration","neg_votes":2,"atr_min":1.1,"accel_max":-0.25,"vwap_max":-0.5},
    {"id":"A3","family":"SHORT_ACCELERATION","kind":"acceleration","neg_votes":2,"atr_min":1.2,"accel_max":-0.25,"vwap_max":-0.5},
    {"id":"A4","family":"SHORT_ACCELERATION","kind":"acceleration","neg_votes":2,"atr_min":1.0,"accel_max":-0.50,"vwap_max":-0.5},
    {"id":"A5","family":"SHORT_ACCELERATION","kind":"acceleration","neg_votes":2,"atr_min":1.1,"accel_max":-0.50,"vwap_max":-1.0},
    {"id":"A6","family":"SHORT_ACCELERATION","kind":"acceleration","neg_votes":2,"atr_min":1.2,"accel_max":-0.50,"vwap_max":-1.0},
    {"id":"F1","family":"SHORT_FAILED_AUCTION_REVERSAL","kind":"failed_auction","neg_votes":1,"body_max":0.0},
    {"id":"F2","family":"SHORT_FAILED_AUCTION_REVERSAL","kind":"failed_auction","neg_votes":1,"vwap_reject":True},
    {"id":"F3","family":"SHORT_FAILED_AUCTION_REVERSAL","kind":"failed_auction","neg_votes":2,"vwap_reject":True},
    {"id":"F4","family":"SHORT_FAILED_AUCTION_REVERSAL","kind":"failed_auction","neg_votes":1,"failed_reclaim":True},
    {"id":"F5","family":"SHORT_FAILED_AUCTION_REVERSAL","kind":"failed_auction","neg_votes":1,"body_max":-0.25},
    {"id":"F6","family":"SHORT_FAILED_AUCTION_REVERSAL","kind":"failed_auction","neg_votes":1,"exclude_bullish":True},
]


def pf(vals):
    gp = sum(x for x in vals if x > 0)
    gl = abs(sum(x for x in vals if x < 0))
    return gp / gl if gl > 0 else (float("inf") if gp > 0 else 0.0)


def metric(vals):
    arr = [float(x) for x in vals]
    return {
        "trades": len(arr),
        "total_r": float(sum(arr)),
        "expectancy_r": float(np.mean(arr)) if arr else 0.0,
        "profit_factor": float(pf(arr)),
        "max_drawdown_r": float(max_drawdown_r(arr)),
        "win_rate": (sum(x > 0 for x in arr) / len(arr)) if arr else 0.0,
    }


def load_market(symbol):
    key = os.getenv("DATABENTO_API_KEY", "")
    if not key:
        raise SystemExit("DATABENTO_API_KEY secret is missing")
    client = _ResilientHistorical(key)
    data = client.timeseries.get_range(
        dataset="GLBX.MDP3",
        schema="ohlcv-1m",
        stype_in="continuous",
        symbols=[symbol],
        start=base.utc_iso(START - timedelta(days=1), 18, 0),
        end=base.utc_iso(END, 16, 0),
    )
    df = data.to_df()
    if df.empty:
        raise SystemExit(f"No discovery data for {symbol}")
    idx = pd.DatetimeIndex(df.index)
    if idx.tz is None:
        idx = idx.tz_localize("UTC")
    work = df.copy()
    work["local_time"] = idx.tz_convert(base.TZ)
    work = work.sort_values("local_time")
    work = work[~work.index.duplicated(keep="first")].copy()
    g = base.enrich_symbol(work).reset_index(drop=True)
    local_date = g["local_time"].dt.date
    g = g[(local_date >= START) & (local_date <= END)].reset_index(drop=True)
    return g


def add_short_features(g):
    close = g["close"].astype(float)
    atr = g["atr14"].astype(float).replace(0.0, np.nan)
    g["slope_fast_atr"] = (close - close.shift(5)) / atr
    g["slope_medium_atr"] = (close - close.shift(20)) / atr
    g["slope_slow_atr"] = (close - close.shift(60)) / atr
    g["slope_accel"] = g["slope_fast_atr"] - g["slope_medium_atr"]
    g["atr_ratio"] = g["atr14"] / g["atr60_med"].replace(0.0, np.nan)
    tr_med = g["tr"].rolling(20).median().shift(1)
    g["range_ratio"] = g["tr"] / tr_med.replace(0.0, np.nan)
    g["volume_ratio"] = g["volume"] / g["volume20"].replace(0.0, np.nan)
    g["body_atr"] = (g["close"] - g["open"]) / atr
    g["breakdown"] = g["close"] < g["prev_low20"]
    g["sweep_high"] = (g["high"] > g["prev_high20"]) & (g["close"] < g["prev_high20"])
    g["failed_reclaim_vwap"] = (g["high"] >= g["vwap"]) & (g["close"] < g["vwap"])
    slopes = np.vstack([
        g["slope_fast_atr"].to_numpy(),
        g["slope_medium_atr"].to_numpy(),
        g["slope_slow_atr"].to_numpy(),
    ]).T
    g["negative_slope_votes"] = np.sum(np.isfinite(slopes) & (slopes < 0), axis=1)
    g["session"] = [base.session_label(ts) for ts in g["local_time"]]
    return g


def template_mask(g, t):
    m = np.ones(len(g), dtype=bool)
    if t["kind"] == "breakdown":
        m &= g["breakdown"].fillna(False).to_numpy()
        m &= (g["slope_medium_atr"].fillna(0).to_numpy() < 0)
    elif t["kind"] == "acceleration":
        m &= (g["slope_fast_atr"].fillna(0).to_numpy() < 0)
        m &= (g["slope_medium_atr"].fillna(0).to_numpy() < 0)
    elif t["kind"] == "failed_auction":
        m &= g["sweep_high"].fillna(False).to_numpy()
        m &= (g["slope_fast_atr"].fillna(0).to_numpy() < 0)
    m &= g["negative_slope_votes"].fillna(0).to_numpy() >= int(t.get("neg_votes", 1))
    if "momentum_max" in t:
        m &= g["momentum10_z"].fillna(999).to_numpy() <= float(t["momentum_max"])
    if "range_min" in t:
        m &= g["range_ratio"].fillna(0).to_numpy() >= float(t["range_min"])
    if "volume_min" in t:
        m &= g["volume_ratio"].fillna(0).to_numpy() >= float(t["volume_min"])
    if "vwap_max" in t:
        m &= g["vwap_z"].fillna(999).to_numpy() <= float(t["vwap_max"])
    if "atr_min" in t:
        m &= g["atr_ratio"].fillna(0).to_numpy() >= float(t["atr_min"])
    if "accel_max" in t:
        m &= g["slope_accel"].fillna(999).to_numpy() <= float(t["accel_max"])
    if "body_max" in t:
        m &= g["body_atr"].fillna(999).to_numpy() <= float(t["body_max"])
    if t.get("vwap_reject"):
        m &= (g["close"].to_numpy() < g["vwap"].to_numpy())
    if t.get("failed_reclaim"):
        m &= g["failed_reclaim_vwap"].fillna(False).to_numpy()
    if t.get("exclude_bullish"):
        m &= g["trend_regime"].astype(str).to_numpy() != "bullish"
    return m


def trades_for(g, mask, rr):
    open_ = g["open"].astype(float).to_numpy(); high = g["high"].astype(float).to_numpy()
    low = g["low"].astype(float).to_numpy(); close = g["close"].astype(float).to_numpy()
    atr = g["atr14"].astype(float).to_numpy(); dates = g["local_time"].tolist()
    out = []
    next_allowed = -1
    for pos in np.flatnonzero(mask):
        pos = int(pos)
        if pos < next_allowed or pos + 1 >= len(g):
            continue
        if not math.isfinite(float(atr[pos])) or float(atr[pos]) <= 0:
            continue
        gross = _trade_outcome_arrays(open_, high, low, close, atr, pos, -1, float(rr))
        if gross is None:
            continue
        out.append((str(dates[pos + 1].date()), float(gross)))
        next_allowed = pos + COOLDOWN_BARS
    return out


def quarter_key(d):
    return f"{d[:4]}Q{((int(d[5:7]) - 1) // 3) + 1}"


def evaluate(symbol, session, template, rr, trades):
    base_vals = [g - COST_R for _, g in trades]
    cost2_vals = [g - 2.0 * COST_R for _, g in trades]
    early = [v for (d, _), v in zip(trades, base_vals) if d <= "2026-03-31"]
    late = [v for (d, _), v in zip(trades, base_vals) if d >= "2026-04-01"]
    quarters = defaultdict(list)
    for (d, _), v in zip(trades, base_vals):
        quarters[quarter_key(d)].append(v)
    eligible_q = [vs for vs in quarters.values() if len(vs) >= 5]
    positive_q = sum(sum(vs) > 0 for vs in eligible_q)
    pos_q_rate = positive_q / len(eligible_q) if eligible_q else 0.0
    qtot = {q: float(sum(vs)) for q, vs in sorted(quarters.items())}
    positive_q_totals = [x for x in qtot.values() if x > 0]
    top_share = (max(positive_q_totals) / sum(positive_q_totals)) if positive_q_totals else 1.0
    bm = metric(base_vals); m2 = metric(cost2_vals); em = metric(early); lm = metric(late)
    fail = []
    if bm["trades"] < MIN_TRADES: fail.append("insufficient_trades")
    if bm["expectancy_r"] <= 0: fail.append("nonpositive_baseline_expectancy")
    if bm["profit_factor"] <= 1.05: fail.append("profit_factor_le_1_05")
    if m2["expectancy_r"] <= 0: fail.append("fails_2x_cost_stress")
    if em["total_r"] <= 0 or lm["total_r"] <= 0: fail.append("internal_walkforward_half_nonpositive")
    if len(eligible_q) < MIN_QUARTERS: fail.append("insufficient_quarter_folds")
    if pos_q_rate < MIN_POSITIVE_QUARTER_RATE: fail.append("unstable_quarter_folds")
    if top_share > MAX_TOP_POSITIVE_QUARTER_SHARE: fail.append("single_period_concentration")
    return {
        "candidate_key": f"{symbol}|{template['family']}|{template['id']}|{session}|RR{rr}",
        "symbol": symbol,
        "direction": "SHORT",
        "family": template["family"],
        "template_id": template["id"],
        "template": template,
        "session": session,
        "rr": float(rr),
        "baseline": bm,
        "cost_stress_2x": m2,
        "early_half": em,
        "late_half": lm,
        "quarter_total_r": qtot,
        "eligible_quarters": len(eligible_q),
        "positive_quarter_rate": pos_q_rate,
        "top_positive_quarter_share": top_share,
        "pre_perturbation_pass": not fail,
        "fail_reasons": fail,
        "trade_returns_2x": cost2_vals,
    }


def mc_p05(vals, seed):
    if not vals:
        return -1e9
    rng = random.Random(seed)
    totals = []
    for _ in range(MC_ITER):
        totals.append(sum(sample_moving_blocks(vals, MC_BLOCK, rng)))
    return float(percentile(totals, 0.05))


def main():
    symbol = os.getenv("SHORT_SYMBOL", "").strip()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported SHORT_SYMBOL={symbol}")
    g = add_short_features(load_market(symbol))
    sessions = sorted(g["session"].dropna().astype(str).unique())
    rows = []
    for template in TEMPLATES:
        base_mask = template_mask(g, template)
        for session in sessions:
            smask = base_mask & (g["session"].astype(str).to_numpy() == session)
            if int(smask.sum()) < 5:
                continue
            for rr in RR_GRID:
                trades = trades_for(g, smask, rr)
                rows.append(evaluate(symbol, session, template, rr, trades))

    by_group = defaultdict(list)
    for row in rows:
        by_group[(row["family"], row["template_id"], row["session"])].append(row)
    for group_rows in by_group.values():
        group_rows.sort(key=lambda r: r["rr"])
        for i, row in enumerate(group_rows):
            neighbors = []
            if i > 0: neighbors.append(group_rows[i-1])
            if i + 1 < len(group_rows): neighbors.append(group_rows[i+1])
            stable = any(n["baseline"]["total_r"] > 0 and n["cost_stress_2x"]["total_r"] > 0 for n in neighbors)
            row["rr_neighbor_positive"] = stable
            if row["pre_perturbation_pass"] and not stable:
                row["fail_reasons"].append("rr_neighbor_not_positive")

    survivors = []
    for idx, row in enumerate(rows, start=1):
        pre_mc = row["pre_perturbation_pass"] and row.get("rr_neighbor_positive", False)
        p05 = mc_p05(row["trade_returns_2x"], 31000 + idx) if pre_mc else None
        row["moving_block_mc_2x_p05_total_r"] = p05
        if pre_mc and (p05 is None or p05 <= 0):
            row["fail_reasons"].append("moving_block_mc_2x_p05_nonpositive")
        row["discovery_pass"] = pre_mc and p05 is not None and p05 > 0
        row.pop("trade_returns_2x", None)
        if row["discovery_pass"]:
            survivors.append(row)

    survivors.sort(key=lambda r: (
        r["late_half"]["expectancy_r"],
        r["moving_block_mc_2x_p05_total_r"],
        r["cost_stress_2x"]["total_r"],
        -r["baseline"]["max_drawdown_r"],
    ), reverse=True)
    family_counts = defaultdict(lambda: {"tested": 0, "passed": 0})
    for r in rows:
        family_counts[r["family"]]["tested"] += 1
        family_counts[r["family"]]["passed"] += int(r["discovery_pass"])
    summary = {
        "phase": "SHORT_NATIVE_ASYMMETRIC_DISCOVERY_V1",
        "symbol": symbol,
        "discovery_window": [str(START), str(END)],
        "rows": len(g),
        "tested_candidates": len(rows),
        "survivors": len(survivors),
        "family_counts": dict(family_counts),
        "rr_grid": RR_GRID,
        "cooldown_bars": COOLDOWN_BARS,
        "baseline_cost_r": COST_R,
        "guardrails": [
            "SHORT is not an inverted LONG template.",
            "NY 09:00-12:00 ET is context only, not a hard time restriction.",
            "2018-2019 is not read or tuned against.",
            "2022-09-01..2025-09-24 remains confirmatory and is not read in this discovery run.",
            "2020-01-02..2022-08-31 remains sealed.",
            "This native pilot does not replace the preregistered StrategyQuant 2,000 raw candidates per market/family target.",
            "LIVE MONEY=false.",
        ],
    }
    OUT.mkdir(exist_ok=True)
    (OUT / f"short_native_discovery_{symbol}.json").write_text(json.dumps({"summary": summary, "survivors": survivors, "all_candidates": rows}, indent=2), encoding="utf-8")
    (OUT / f"short_native_discovery_{symbol}_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print("SHORT_NATIVE_DISCOVERY_OK")
    print(json.dumps(summary, indent=2))


if __name__ == "__main__":
    main()
