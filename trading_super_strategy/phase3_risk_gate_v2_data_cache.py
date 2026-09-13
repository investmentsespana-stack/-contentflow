"""Download and persist the exact Phase 3 Risk Gate V2 market window.

This isolates the fragile historical transport from the statistical calculation.
The cached artifact contains only the already-approved confirmatory window
2022-09-01..2025-09-24; the reserved 2020-01-02..2022-08-31 holdout is never
requested here.
"""

from __future__ import annotations

import hashlib
import os
from datetime import date
from pathlib import Path

import pandas as pd

import real_strategy_discovery as base
from phase3_multiyear_validation import VALIDATION_END, VALIDATION_START
from phase3_risk_gate_v2_resilient import _ResilientHistorical


def main() -> None:
    api_key = os.getenv("DATABENTO_API_KEY", "")
    if not api_key:
        raise SystemExit("DATABENTO_API_KEY secret is missing")

    symbol = os.getenv("PHASE3_SYMBOL", "").strip()
    if symbol not in base.SYMBOLS:
        raise SystemExit(f"Unsupported PHASE3_SYMBOL: {symbol}")

    start_date = date.fromisoformat(VALIDATION_START)
    end_date = date.fromisoformat(VALIDATION_END)
    client = _ResilientHistorical(api_key)
    data = client.timeseries.get_range(
        dataset="GLBX.MDP3",
        schema="ohlcv-1m",
        stype_in="continuous",
        symbols=[symbol],
        start=base.utc_iso(start_date, 18, 0),
        end=base.utc_iso(end_date, 16, 0),
    )
    df = data.to_df()
    if df.empty:
        raise SystemExit("No Databento rows returned for Phase 3 V2 cache")

    df = df.sort_index()
    df = df[~df.index.duplicated(keep="first")].copy()

    out = Path("phase3_risk_gate_v2_data_cache")
    out.mkdir(exist_ok=True)
    target = out / f"{symbol}.parquet"
    df.to_parquet(target, index=True)

    digest = hashlib.sha256(target.read_bytes()).hexdigest()
    idx = pd.DatetimeIndex(df.index)
    print(
        "PHASE3_V2_DATA_CACHE_OK "
        f"symbol={symbol} rows={len(df)} start={idx.min()} end={idx.max()} "
        f"sha256={digest} file={target}",
        flush=True,
    )


if __name__ == "__main__":
    main()
