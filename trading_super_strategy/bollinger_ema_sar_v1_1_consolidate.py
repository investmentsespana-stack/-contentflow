"""Consolidate per-market Bollinger/EMA/SAR v1.1 artifacts."""
from __future__ import annotations

import json
from pathlib import Path

import bollinger_ema_sar_v1_consolidate as base

ROOT = Path("bollinger_ema_sar_v1_1_downloads")
OUT = Path("bollinger_ema_sar_v1_1_crossmarket")


def main() -> None:
    base.ROOT = ROOT
    base.OUT = OUT
    base.main()
    path = OUT / "crossmarket_summary.json"
    data = json.loads(path.read_text(encoding="utf-8"))
    data["strategy"] = "bollinger_ema_sar_v1_1"
    data["change_from_v1"] = "slope_filter_only"
    data["slope_filter"] = {
        "direction": "EMA20[t]-EMA20[t-3] sign",
        "strength": "abs(EMA20[t]-EMA20[t-3])/ATR14",
        "sideways": "NO_TRADE when strength <= causal prior-60-bar Q25",
        "optimized": False
    }
    path.write_text(json.dumps(data, indent=2), encoding="utf-8")


if __name__ == "__main__":
    main()
