"""Consolidate causal A/B/C shards and build causal portfolio variant D.

D uses only trailing daily returns available before each allocation date: inverse
realized volatility with a positive-correlation penalty and a concentration cap.
This is research-only; it cannot approve paper or live trading.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import numpy as np
import pandas as pd

from robustness_engine import max_drawdown_r


def _portfolio_metrics(series: pd.Series) -> dict:
    values = [float(x) for x in series.fillna(0.0).tolist()]
    if not values:
        return {"days": 0, "total_r": 0.0, "mean_daily_r": 0.0, "daily_vol_r": 0.0, "sharpe_annualized": 0.0, "max_drawdown_r": 0.0, "positive_day_rate": 0.0}
    arr = np.asarray(values, dtype=float)
    mu = float(arr.mean())
    vol = float(arr.std(ddof=0))
    return {
        "days": len(values),
        "total_r": float(arr.sum()),
        "mean_daily_r": mu,
        "daily_vol_r": vol,
        "sharpe_annualized": float(math.sqrt(252.0) * mu / vol) if vol > 0 else 0.0,
        "max_drawdown_r": float(max_drawdown_r(values)),
        "positive_day_rate": float((arr > 0).mean()),
    }


def _mean_pairwise_corr(frame: pd.DataFrame) -> float | None:
    if frame.shape[1] < 2 or frame.shape[0] < 3:
        return None
    corr = frame.corr().to_numpy(dtype=float)
    tri = corr[np.triu_indices_from(corr, k=1)]
    tri = tri[np.isfinite(tri)]
    return float(tri.mean()) if len(tri) else None


def _capped_weights(raw: pd.Series, cap: float = 0.20) -> pd.Series:
    raw = raw.replace([np.inf, -np.inf], np.nan).dropna()
    raw = raw[raw > 0]
    if raw.empty:
        return raw
    w = raw / raw.sum()
    effective_cap = max(cap, 1.0 / len(w))
    free = set(w.index)
    fixed = pd.Series(0.0, index=w.index)
    remaining = 1.0
    while free:
        subtotal = raw[list(free)].sum()
        if subtotal <= 0:
            break
        trial = raw[list(free)] / subtotal * remaining
        over = trial[trial > effective_cap]
        if over.empty:
            fixed.loc[list(free)] = trial
            break
        for name in over.index:
            fixed.loc[name] = effective_cap
            remaining -= effective_cap
            free.remove(name)
        if remaining <= 1e-12:
            break
    total = fixed.sum()
    return fixed / total if total > 0 else fixed


def _lifecycle(row: dict) -> str:
    a = row["variant_a_base"]
    b = row["variant_b_regime"]
    c = row["variant_c_vol_target"]
    if c["trades"] >= 60 and c["expectancy_r"] > 0 and c["profit_factor"] > 1.05 and c["max_drawdown_r"] <= a["max_drawdown_r"]:
        return "ACTIVE_RESEARCH"
    if c["expectancy_r"] > 0 and b["expectancy_r"] > 0:
        return "REDUCED_RESEARCH"
    if a["expectancy_r"] > 0:
        return "WATCH_RESEARCH"
    return "OFF_RESEARCH"


def main() -> None:
    shard_dir = Path("regime_abcd_shards")
    files = sorted(shard_dir.glob("rr_*.json"))
    if not files:
        raise SystemExit("No REGIME_ABCD shard files found")

    candidates = []
    symbol = None
    for path in files:
        payload = json.loads(path.read_text(encoding="utf-8"))
        symbol = symbol or payload.get("symbol")
        if payload.get("symbol") != symbol:
            raise SystemExit(f"Mixed symbols in experiment shards: {path}")
        candidates.extend(payload.get("candidates", []))
    if not candidates:
        raise SystemExit("REGIME_ABCD has no frozen candidates")

    for row in candidates:
        row["lifecycle_research_state"] = _lifecycle(row)

    dates = sorted({d for row in candidates for d in row.get("daily_returns_c", {}).keys()})
    keys = [row["candidate_key"] for row in candidates]
    daily = pd.DataFrame(0.0, index=pd.Index(dates, name="date"), columns=keys)
    for row in candidates:
        for day, value in row.get("daily_returns_c", {}).items():
            daily.at[day, row["candidate_key"]] = float(value)

    equal_c = daily.mean(axis=1) if not daily.empty else pd.Series(dtype=float)
    d_returns = []
    weight_log = []
    lookback = 60
    warmup = 20
    for i, day in enumerate(daily.index):
        if i < warmup:
            d_returns.append(0.0)
            weight_log.append({"date": day, "eligible": 0, "max_weight": 0.0})
            continue
        hist = daily.iloc[max(0, i - lookback):i]
        vols = hist.std(ddof=0)
        eligible = vols[(vols > 1e-9) & np.isfinite(vols)].index.tolist()
        if not eligible:
            d_returns.append(0.0)
            weight_log.append({"date": day, "eligible": 0, "max_weight": 0.0})
            continue
        hist_e = hist[eligible]
        corr = hist_e.corr().fillna(0.0)
        penalties = {}
        for name in eligible:
            others = corr.loc[name].drop(labels=[name], errors="ignore")
            positive = others[others > 0]
            penalties[name] = 1.0 + (float(positive.mean()) if len(positive) else 0.0)
        raw = pd.Series({name: 1.0 / float(vols[name]) / penalties[name] for name in eligible})
        weights = _capped_weights(raw, cap=0.20)
        today = daily.iloc[i]
        d_return = float((today.reindex(weights.index).fillna(0.0) * weights).sum())
        d_returns.append(d_return)
        weight_log.append({
            "date": day,
            "eligible": int(len(weights)),
            "max_weight": float(weights.max()) if len(weights) else 0.0,
            "effective_number": float(1.0 / (weights.pow(2).sum())) if len(weights) and weights.pow(2).sum() > 0 else 0.0,
        })

    d_series = pd.Series(d_returns, index=daily.index, dtype=float)
    comparable_equal_c = equal_c.iloc[warmup:] if len(equal_c) > warmup else equal_c.iloc[0:0]
    comparable_d = d_series.iloc[warmup:] if len(d_series) > warmup else d_series.iloc[0:0]

    drawdown_days = equal_c[equal_c < 0].index
    mean_corr_all = _mean_pairwise_corr(daily)
    mean_corr_down = _mean_pairwise_corr(daily.loc[drawdown_days]) if len(drawdown_days) else None

    improvements = {
        "total_candidates": len(candidates),
        "b_expectancy_gt_a": sum(1 for r in candidates if r["variant_b_regime"]["expectancy_r"] > r["variant_a_base"]["expectancy_r"]),
        "b_drawdown_lt_a": sum(1 for r in candidates if r["variant_b_regime"]["max_drawdown_r"] < r["variant_a_base"]["max_drawdown_r"]),
        "c_drawdown_lt_a": sum(1 for r in candidates if r["variant_c_vol_target"]["max_drawdown_r"] < r["variant_a_base"]["max_drawdown_r"]),
        "c_positive_expectancy": sum(1 for r in candidates if r["variant_c_vol_target"]["expectancy_r"] > 0),
        "active_research": sum(1 for r in candidates if r["lifecycle_research_state"] == "ACTIVE_RESEARCH"),
        "reduced_research": sum(1 for r in candidates if r["lifecycle_research_state"] == "REDUCED_RESEARCH"),
        "watch_research": sum(1 for r in candidates if r["lifecycle_research_state"] == "WATCH_RESEARCH"),
        "off_research": sum(1 for r in candidates if r["lifecycle_research_state"] == "OFF_RESEARCH"),
    }

    cell_agg = {}
    for row in candidates:
        for cell in row.get("feature_cells_a", []):
            key = (cell["slope_state"], cell["volatility_change"], cell["relative_volume"])
            slot = cell_agg.setdefault(key, {"trades": 0, "weighted_expectancy_sum": 0.0, "weighted_win_sum": 0.0})
            n = int(cell["trades"])
            slot["trades"] += n
            slot["weighted_expectancy_sum"] += n * float(cell["expectancy_r"])
            slot["weighted_win_sum"] += n * float(cell["win_rate"])
    feature_cells = []
    for key, slot in sorted(cell_agg.items()):
        n = slot["trades"]
        feature_cells.append({
            "slope_state": key[0],
            "volatility_change": key[1],
            "relative_volume": key[2],
            "trades": n,
            "weighted_expectancy_r": slot["weighted_expectancy_sum"] / n if n else 0.0,
            "weighted_win_rate": slot["weighted_win_sum"] / n if n else 0.0,
        })

    out = Path("regime_abcd_output")
    out.mkdir(exist_ok=True)
    summary = {
        "experiment": "REGIME_ABCD_V1",
        "symbol": symbol,
        "validation_window": "2022-09-01/2025-09-24",
        "reserved_untouched_holdout": "2020-01-02/2022-08-31",
        "variants": {
            "A": "Frozen candidate/context unchanged",
            "B": "A + causal multi-horizon slope agreement + trailing relative trend-quality filter",
            "C": "B + volatility-targeted exposure clipped to 0.25..1.00 of baseline",
            "D": "C portfolio + trailing 60-day inverse-volatility allocation with positive-correlation penalty and concentration cap",
        },
        "candidate_improvements": improvements,
        "portfolio_c_equal_weight_comparable": _portfolio_metrics(comparable_equal_c),
        "portfolio_d_dynamic_comparable": _portfolio_metrics(comparable_d),
        "mean_pairwise_candidate_correlation_all_days": mean_corr_all,
        "mean_pairwise_candidate_correlation_on_negative_portfolio_days": mean_corr_down,
        "feature_cells_a_aggregate": feature_cells,
        "weight_log_tail": weight_log[-20:],
        "research_guardrails": [
            "No thresholds were selected by looking at the final 2020-2022 holdout; that holdout remains untouched.",
            "B uses only sign agreement and a trailing shifted relative trend-quality threshold.",
            "C never increases exposure above the frozen baseline.",
            "D weights use only returns strictly prior to each allocation date.",
            "Lifecycle labels are research states only and do not authorize paper or live trading.",
            "Live money remains disabled.",
        ],
    }

    (out / "regime_abcd_summary.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    (out / "regime_abcd_candidates.json").write_text(json.dumps(candidates, indent=2), encoding="utf-8")
    daily.assign(variant_c_equal_weight=equal_c, variant_d_dynamic=d_series).to_csv(out / "regime_abcd_daily_portfolio.csv")

    print("REGIME_ABCD_CONSOLIDATED_OK", flush=True)
    print(json.dumps(summary, indent=2), flush=True)


if __name__ == "__main__":
    main()
