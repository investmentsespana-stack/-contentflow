"""Slope-only follow-up to Bollinger/EMA/SAR v1.

Everything except the sideways/slope filter is inherited unchanged from v1.
Discovery window and data-governance boundaries remain identical.
"""
from __future__ import annotations

import json
from pathlib import Path

import pandas as pd

import bollinger_ema_sar_v1_backtest as base

OUT = Path("bollinger_ema_sar_v1_1_output")
_BASE_ENRICH = base.enrich
_BASE_SIGNAL_MASKS = base.signal_masks


def enrich_v1_1(g: pd.DataFrame) -> pd.DataFrame:
    g = _BASE_ENRICH(g)
    prev_close = g["close"].astype(float).shift(1)
    tr = pd.concat(
        [
            g["high"].astype(float) - g["low"].astype(float),
            (g["high"].astype(float) - prev_close).abs(),
            (g["low"].astype(float) - prev_close).abs(),
        ],
        axis=1,
    ).max(axis=1)
    g["atr14"] = tr.rolling(14, min_periods=14).mean()
    g["ema20_slope_delta_3"] = g["ema20"] - g["ema20"].shift(3)
    g["ema20_slope_strength"] = (
        g["ema20_slope_delta_3"].abs() / g["atr14"].replace(0.0, float("nan"))
    )
    # Causal adaptive flat-market threshold: bottom quartile of PRIOR slope strengths.
    g["ema20_slope_q25_prior60"] = (
        g["ema20_slope_strength"].shift(1).rolling(60, min_periods=20).quantile(0.25)
    )
    return g


def _combine(parts: dict[str, pd.Series]) -> pd.Series:
    active = pd.Series(True, index=next(iter(parts.values())).index)
    for mask in parts.values():
        active &= mask.fillna(False)
    return active


def signal_masks_v1_1(g: pd.DataFrame):
    long_parts, short_parts, _, _, pats = _BASE_SIGNAL_MASKS(g)
    strength_ok = g["ema20_slope_strength"] > g["ema20_slope_q25_prior60"]
    long_parts["ema20_slope"] = (g["ema20_slope_delta_3"] > 0) & strength_ok
    short_parts["ema20_slope"] = (g["ema20_slope_delta_3"] < 0) & strength_ok
    return long_parts, short_parts, _combine(long_parts), _combine(short_parts), pats


def patch_summary_files() -> None:
    for path in OUT.glob("*_summary.json"):
        data = json.loads(path.read_text(encoding="utf-8"))
        data["strategy"] = "bollinger_ema_sar_v1_1"
        data["change_from_v1"] = "slope_filter_only"
        data["slope_filter"] = {
            "direction": "EMA20[t]-EMA20[t-3] sign",
            "strength": "abs(EMA20[t]-EMA20[t-3])/ATR14",
            "sideways": "NO_TRADE when strength <= causal prior-60-bar Q25",
            "optimized": False,
        }
        path.write_text(json.dumps(data, indent=2), encoding="utf-8")


def main() -> None:
    base.OUT = OUT
    base.enrich = enrich_v1_1
    base.signal_masks = signal_masks_v1_1
    base.main()
    patch_summary_files()


if __name__ == "__main__":
    main()
