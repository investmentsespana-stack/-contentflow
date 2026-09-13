"""Causal A/B/C regime experiment on frozen Phase 2 candidates.

A = frozen strategy/context unchanged.
B = A + directional multi-horizon slope compatibility and locally relative trend quality.
C = B + volatility-targeted risk scaling that can only reduce baseline exposure.

All features are known at signal-bar close; entry remains next-bar open. No 2020-2022
holdout data is queried. This module is research-only and cannot enable live trading.
"""

from __future__ import annotations

import json
import math
import os
from collections import defaultdict
from pathlib import Path

import numpy as np
import pandas as pd

import real_strategy_discovery as base
from phase2_historical_search import _trade_outcome_arrays
from phase3_multiyear_validation import (
    BASELINE_COST_R,
    candidate_key,
    freeze_exact_intersection,
    metrics,
)


def _label(rr: float) -> str:
    return str(rr).replace(".", "p")


def _direction_value(value) -> int:
    if isinstance(value, str):
        return 1 if value.upper() == "LONG" else -1
    return 1 if int(value) > 0 else -1


def _safe_metrics(values):
    return metrics([float(x) for x in values])


def _feature_cells(records):
    grouped = defaultdict(list)
    for row in records:
        key = (
            "aligned" if row["slope_aligned"] else "not_aligned",
            "vol_expanding" if row["vol_slope"] > 0 else "vol_contracting_or_flat",
            "rel_volume_ge_1" if row["rel_volume"] >= 1.0 else "rel_volume_lt_1",
        )
        grouped[key].append(row["return_a"])
    out = []
    for key, values in sorted(grouped.items()):
        m = _safe_metrics(values)
        out.append({
            "slope_state": key[0],
            "volatility_change": key[1],
            "relative_volume": key[2],
            "trades": m["trades"],
            "win_rate": m["win_rate"],
            "expectancy_r": m["expectancy_r"],
            "profit_factor": m["profit_factor"],
            "max_drawdown_r": m["max_drawdown_r"],
        })
    return out


def main() -> None:
    symbol = os.getenv("PHASE3_SYMBOL", "ES.v.0").strip()
    rr = float(os.environ["PHASE3_RR_FILTER"])
    cache_path = Path(os.environ["PHASE3_V2_INPUT_PARQUET"])
    if not cache_path.exists():
        raise SystemExit(f"Missing cached validation parquet: {cache_path}")

    frozen_all = freeze_exact_intersection(symbol)
    candidates = [row for row in frozen_all if float(row["rr"]) == rr]
    out = Path("regime_abcd_shards")
    out.mkdir(exist_ok=True)
    target = out / f"rr_{_label(rr)}.json"
    if not candidates:
        target.write_text(json.dumps({"symbol": symbol, "rr": rr, "candidates": []}, indent=2), encoding="utf-8")
        print(f"REGIME_ABCD_EMPTY symbol={symbol} rr={rr}", flush=True)
        return

    df = pd.read_parquet(cache_path)
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
    eps = 1e-12
    g["slope_fast_atr"] = (close - close.shift(5)) / atr.replace(0.0, np.nan)
    g["slope_medium_atr"] = (close - close.shift(20)) / atr.replace(0.0, np.nan)
    g["slope_slow_atr"] = (close - close.shift(60)) / atr.replace(0.0, np.nan)

    path20 = close.diff().abs().rolling(20).sum()
    g["trend_efficiency20"] = (close - close.shift(20)).abs() / path20.replace(0.0, np.nan)
    # Relative threshold uses only previously observed trend-efficiency values.
    g["trend_efficiency_threshold"] = (
        g["trend_efficiency20"].rolling(120, min_periods=60).median().shift(1)
    )

    prior_atr = atr.shift(10)
    g["vol_slope"] = (atr - prior_atr) / prior_atr.replace(0.0, np.nan)
    g["vol_accel"] = g["vol_slope"] - g["vol_slope"].shift(10)
    prior_vol_mean = g["volume"].astype(float).rolling(20, min_periods=10).mean().shift(1)
    g["relative_volume"] = g["volume"].astype(float) / prior_vol_mean.replace(0.0, np.nan)

    prior_vol_target = g["atr60_med"].shift(1)
    g["risk_scale"] = (prior_vol_target / atr.replace(0.0, np.nan)).clip(lower=0.25, upper=1.0)

    local_times = g["local_time"].tolist()
    session_arr = np.array([base.session_label(ts) for ts in local_times], dtype=object)
    bucket_arr = np.array([base.open_bucket(ts) for ts in local_times], dtype=object)
    vol_regime = g["vol_regime"].astype(str).to_numpy()
    trend_regime = g["trend_regime"].astype(str).to_numpy()
    structure_regime = g["structure_regime"].astype(str).to_numpy()
    signal_arrays = {
        name: g[f"sig_{name}"].fillna(0).astype(int).to_numpy()
        for name in base.STRATEGIES
    }

    open_ = g["open"].astype(float).to_numpy()
    high = g["high"].astype(float).to_numpy()
    low = g["low"].astype(float).to_numpy()
    close_arr = g["close"].astype(float).to_numpy()
    atr_arr = g["atr14"].astype(float).to_numpy()
    sf = g["slope_fast_atr"].to_numpy()
    sm = g["slope_medium_atr"].to_numpy()
    ss = g["slope_slow_atr"].to_numpy()
    eff = g["trend_efficiency20"].to_numpy()
    eff_thr = g["trend_efficiency_threshold"].to_numpy()
    vol_slope = g["vol_slope"].to_numpy()
    vol_accel = g["vol_accel"].to_numpy()
    rel_volume = g["relative_volume"].to_numpy()
    risk_scale = g["risk_scale"].to_numpy()

    results = []
    for candidate in candidates:
        direction = _direction_value(candidate["direction"])
        context = candidate["context"]
        members = candidate["members"]

        mask = (
            (session_arr == context["session"])
            & (bucket_arr == context["minutes_from_open_bucket"])
            & (vol_regime == context["volatility_regime"])
            & (trend_regime == context["trend_regime"])
            & (structure_regime == context["structure_regime"])
        )
        for member in members:
            mask &= signal_arrays[member] == direction

        positions = np.flatnonzero(mask)
        a_returns = []
        b_returns = []
        c_returns = []
        c_daily = defaultdict(float)
        feature_records = []

        for pos in positions:
            if pos + 1 >= len(g) or not math.isfinite(float(atr_arr[pos])) or atr_arr[pos] <= 0:
                continue
            gross = _trade_outcome_arrays(open_, high, low, close_arr, atr_arr, int(pos), direction, rr)
            if gross is None:
                continue
            net = float(gross) - BASELINE_COST_R
            a_returns.append(net)

            slopes = (sf[pos], sm[pos], ss[pos])
            directional_votes = sum(
                1 for value in slopes
                if math.isfinite(float(value)) and direction * float(value) > 0.0
            )
            quality_ok = (
                math.isfinite(float(eff[pos]))
                and math.isfinite(float(eff_thr[pos]))
                and float(eff[pos]) >= float(eff_thr[pos])
            )
            aligned = directional_votes >= 2 and quality_ok

            rv = float(rel_volume[pos]) if math.isfinite(float(rel_volume[pos])) else 1.0
            vs = float(vol_slope[pos]) if math.isfinite(float(vol_slope[pos])) else 0.0
            va = float(vol_accel[pos]) if math.isfinite(float(vol_accel[pos])) else 0.0
            feature_records.append({
                "slope_aligned": bool(aligned),
                "vol_slope": vs,
                "vol_accel": va,
                "rel_volume": rv,
                "return_a": net,
            })

            if not aligned:
                continue
            b_returns.append(net)
            scale = float(risk_scale[pos]) if math.isfinite(float(risk_scale[pos])) else 1.0
            scale = min(1.0, max(0.25, scale))
            scaled = net * scale
            c_returns.append(scaled)
            day = str(local_times[pos + 1].date())
            c_daily[day] += scaled

        result = {
            **candidate,
            "candidate_key": candidate_key(candidate),
            "variant_a_base": _safe_metrics(a_returns),
            "variant_b_regime": _safe_metrics(b_returns),
            "variant_c_vol_target": _safe_metrics(c_returns),
            "trade_retention_b_vs_a": len(b_returns) / len(a_returns) if a_returns else 0.0,
            "daily_returns_c": dict(sorted(c_daily.items())),
            "feature_cells_a": _feature_cells(feature_records),
            "causality_notes": [
                "All regime features are evaluated at signal-bar close and entry remains next-bar open.",
                "B requires at least two of fast/medium/slow ATR-normalized slopes to agree with direction.",
                "B trend-quality threshold is a trailing 120-observation median shifted one bar; it is not fitted on future returns.",
                "C scales B exposure by prior ATR60 median divided by current ATR14, clipped to 0.25..1.00, so it never leverages above baseline.",
                "No 2020-01-02/2022-08-31 holdout data is used.",
            ],
        }
        results.append(result)

    payload = {
        "experiment": "REGIME_ABCD_V1",
        "symbol": symbol,
        "rr": rr,
        "validation_window": "2022-09-01/2025-09-24",
        "reserved_untouched_holdout": "2020-01-02/2022-08-31",
        "rows": len(g),
        "candidates": results,
    }
    target.write_text(json.dumps(payload, indent=2), encoding="utf-8")
    print(f"REGIME_ABCD_RR_OK symbol={symbol} rr={rr} candidates={len(results)}", flush=True)


if __name__ == "__main__":
    main()
