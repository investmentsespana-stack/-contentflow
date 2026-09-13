"""Build pre-registered LONG/SHORT portfolios from the 38 frozen ACTIVE_RESEARCH candidates.

Portfolio construction intentionally ignores the later individual robustness outcome.
The source set is the already-frozen ACTIVE_RESEARCH selection. Four deterministic
weighting schemes are created per direction: equal, market-balanced, family-balanced,
and session-balanced. No return-based optimization is used. B/C rules are replayed
exactly to obtain daily gross R and exact cost exposure. Final holdout 2020-01-02..
2022-08-31 is never read. Research only; LIVE MONEY remains false.
"""
from __future__ import annotations

import json, math
from collections import defaultdict
from pathlib import Path
import numpy as np
import pandas as pd
import real_strategy_discovery as base
from phase2_historical_search import _trade_outcome_arrays
from phase3_multiyear_validation import BASELINE_COST_R

SOURCE = Path("portfolio_inputs/active_robustness_crossmarket_candidates.json")
CACHE_DIR = Path("phase3_risk_gate_v2_data_cache")
OUT = Path("directional_portfolio_output")


def direction_value(value):
    return 1 if str(value).upper() == "LONG" else -1


def family(row):
    return "+".join(row.get("members", []))


def build_features(path: Path):
    df = pd.read_parquet(path)
    idx = pd.DatetimeIndex(df.index)
    if idx.tz is None:
        idx = idx.tz_localize("UTC")
    work = df.copy()
    work["local_time"] = idx.tz_convert(base.TZ)
    work = work.sort_values("local_time")
    work = work[~work.index.duplicated(keep="first")].copy()
    g = base.enrich_symbol(work).reset_index(drop=True)
    close = g["close"].astype(float)
    atr = g["atr14"].astype(float)
    g["slope_fast_atr"] = (close - close.shift(5)) / atr.replace(0.0, np.nan)
    g["slope_medium_atr"] = (close - close.shift(20)) / atr.replace(0.0, np.nan)
    g["slope_slow_atr"] = (close - close.shift(60)) / atr.replace(0.0, np.nan)
    path20 = close.diff().abs().rolling(20).sum()
    g["trend_efficiency20"] = (close - close.shift(20)).abs() / path20.replace(0.0, np.nan)
    g["trend_efficiency_threshold"] = g["trend_efficiency20"].rolling(120, min_periods=60).median().shift(1)
    target = g["atr60_med"].shift(1)
    g["risk_scale"] = (target / atr.replace(0.0, np.nan)).clip(lower=0.25, upper=1.0)
    return g


def replay_candidate(g, row):
    local_times = g["local_time"].tolist()
    session_arr = np.array([base.session_label(ts) for ts in local_times], dtype=object)
    bucket_arr = np.array([base.open_bucket(ts) for ts in local_times], dtype=object)
    vol_regime = g["vol_regime"].astype(str).to_numpy()
    trend_regime = g["trend_regime"].astype(str).to_numpy()
    structure_regime = g["structure_regime"].astype(str).to_numpy()
    signal_arrays = {name: g[f"sig_{name}"].fillna(0).astype(int).to_numpy() for name in base.STRATEGIES}
    open_ = g["open"].astype(float).to_numpy(); high = g["high"].astype(float).to_numpy()
    low = g["low"].astype(float).to_numpy(); close = g["close"].astype(float).to_numpy()
    atr = g["atr14"].astype(float).to_numpy(); sf = g["slope_fast_atr"].to_numpy()
    sm = g["slope_medium_atr"].to_numpy(); ss = g["slope_slow_atr"].to_numpy()
    eff = g["trend_efficiency20"].to_numpy(); eff_thr = g["trend_efficiency_threshold"].to_numpy()
    scale_arr = g["risk_scale"].to_numpy()
    c = row["context"]; d = direction_value(row["direction"]); rr = float(row["rr"])
    mask = ((session_arr == c["session"]) & (bucket_arr == c["minutes_from_open_bucket"]) &
            (vol_regime == c["volatility_regime"]) & (trend_regime == c["trend_regime"]) &
            (structure_regime == c["structure_regime"]))
    for member in row["members"]:
        mask &= signal_arrays[member] == d
    daily_gross = defaultdict(float); daily_cost_units = defaultdict(float)
    trades = 0; scaled_total = 0.0
    for pos in np.flatnonzero(mask):
        if pos + 1 >= len(g) or not math.isfinite(float(atr[pos])) or atr[pos] <= 0:
            continue
        gross = _trade_outcome_arrays(open_, high, low, close, atr, int(pos), d, rr)
        if gross is None:
            continue
        votes = sum(1 for v in (sf[pos], sm[pos], ss[pos]) if math.isfinite(float(v)) and d * float(v) > 0)
        quality = math.isfinite(float(eff[pos])) and math.isfinite(float(eff_thr[pos])) and float(eff[pos]) >= float(eff_thr[pos])
        if votes < 2 or not quality:
            continue
        scale = float(scale_arr[pos]) if math.isfinite(float(scale_arr[pos])) else 1.0
        scale = min(1.0, max(0.25, scale))
        day = str(local_times[pos + 1].date())
        daily_gross[day] += float(gross) * scale
        daily_cost_units[day] += scale
        scaled_total += (float(gross) - BASELINE_COST_R) * scale
        trades += 1
    expected = row.get("variant_c_metrics", {}).get("total_r")
    if expected is not None and abs(float(expected) - scaled_total) > 1e-6 * max(1.0, abs(float(expected))):
        raise SystemExit(f"Replay mismatch {row['candidate_key']}: expected={expected} got={scaled_total}")
    return {"gross": dict(daily_gross), "cost_units": dict(daily_cost_units), "trades": trades}


def weights(rows, scheme):
    if scheme == "EQUAL_ALL":
        return {r["candidate_key"]: 1.0 / len(rows) for r in rows}
    field = {"MARKET_BALANCED": lambda r: r["symbol"],
             "FAMILY_BALANCED": family,
             "SESSION_BALANCED": lambda r: r["context"]["session"]}[scheme]
    groups = defaultdict(list)
    for r in rows:
        groups[field(r)].append(r)
    return {r["candidate_key"]: (1.0 / len(groups)) / len(groups[field(r)]) for r in rows}


def main():
    rows = json.loads(SOURCE.read_text(encoding="utf-8"))
    active = [r for r in rows if r.get("selection_state") == "ACTIVE_RESEARCH_FROZEN"]
    if len(active) != 38:
        raise SystemExit(f"Expected frozen 38 ACTIVE_RESEARCH candidates, got {len(active)}")
    by_symbol = defaultdict(list)
    for r in active: by_symbol[r["symbol"]].append(r)
    replay = {}; all_dates = set()
    for symbol, items in by_symbol.items():
        path = CACHE_DIR / f"{symbol}.parquet"
        if not path.exists(): raise SystemExit(f"Missing checkpoint {path}")
        g = build_features(path)
        for r in items:
            x = replay_candidate(g, r); replay[r["candidate_key"]] = x
            all_dates.update(x["gross"]); all_dates.update(x["cost_units"])
    dates = sorted(all_dates)
    portfolios = []
    for direction in ("LONG", "SHORT"):
        selected = [r for r in active if r["direction"] == direction]
        for scheme in ("EQUAL_ALL", "MARKET_BALANCED", "FAMILY_BALANCED", "SESSION_BALANCED"):
            w = weights(selected, scheme)
            gross = {d: 0.0 for d in dates}; cost_units = {d: 0.0 for d in dates}
            for r in selected:
                ww = w[r["candidate_key"]]; x = replay[r["candidate_key"]]
                for d, v in x["gross"].items(): gross[d] += ww * float(v)
                for d, v in x["cost_units"].items(): cost_units[d] += ww * float(v)
            portfolios.append({
                "portfolio_id": f"{direction}_{scheme}", "direction": direction, "scheme": scheme,
                "component_count": len(selected),
                "components": [{"candidate_key": r["candidate_key"], "symbol": r["symbol"],
                    "members": r["members"], "rr": r["rr"], "context": r["context"],
                    "weight": w[r["candidate_key"]]} for r in selected],
                "daily_gross_r": gross, "daily_cost_units": cost_units,
            })
    OUT.mkdir(exist_ok=True)
    summary = {
        "formation": "DIRECTIONAL_PORTFOLIO_V1", "source_candidates": len(active),
        "long_components": sum(r["direction"] == "LONG" for r in active),
        "short_components": sum(r["direction"] == "SHORT" for r in active),
        "portfolio_count": len(portfolios),
        "schemes": ["EQUAL_ALL", "MARKET_BALANCED", "FAMILY_BALANCED", "SESSION_BALANCED"],
        "selection_rule": "Use all candidates frozen as ACTIVE_RESEARCH before the individual robustness audit; ignore later individual pass/fail when forming portfolios.",
        "guardrails": ["No return-optimized weights.", "LONG and SHORT are never mixed.",
            "B/C rules replayed exactly; C never exceeds baseline exposure.",
            "Holdout 2020-01-02/2022-08-31 is not read.", "LIVE MONEY=false."],
    }
    (OUT / "directional_portfolios.json").write_text(json.dumps(portfolios, indent=2), encoding="utf-8")
    (OUT / "directional_portfolio_formation_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print("DIRECTIONAL_PORTFOLIOS_FROZEN_OK")
    print(json.dumps(summary, indent=2))

if __name__ == "__main__": main()
