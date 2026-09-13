"""Run Phase 3 Risk Gate V2 against a previously persisted market-data artifact.

The statistical validator is not modified. Only Databento transport is replaced by
an immutable local parquet input produced for the exact approved validation window.
"""

from __future__ import annotations

import os
from pathlib import Path

import pandas as pd

import phase3_risk_gate_v2 as v2


class _CachedResult:
    def __init__(self, frame: pd.DataFrame):
        self._frame = frame

    def to_df(self) -> pd.DataFrame:
        return self._frame.copy()


class _CachedTimeseries:
    def __init__(self, cache_path: Path):
        self._cache_path = cache_path

    def get_range(self, *args, **kwargs):
        frame = pd.read_parquet(self._cache_path)
        if frame.empty:
            raise RuntimeError(f"Cached Phase 3 input is empty: {self._cache_path}")
        print(
            f"PHASE3_V2_CACHE_LOAD file={self._cache_path} rows={len(frame)}",
            flush=True,
        )
        return _CachedResult(frame)


class _CachedHistorical:
    def __init__(self, api_key: str):
        cache = os.getenv("PHASE3_V2_INPUT_PARQUET", "").strip()
        if not cache:
            raise RuntimeError("PHASE3_V2_INPUT_PARQUET is missing")
        path = Path(cache)
        if not path.exists():
            raise RuntimeError(f"PHASE3_V2_INPUT_PARQUET does not exist: {path}")
        self.timeseries = _CachedTimeseries(path)


def main() -> None:
    v2.db.Historical = _CachedHistorical
    v2.main()


if __name__ == "__main__":
    main()
