"""NQ recovery runner for Phase 3 Risk Gate V2.

Root-cause repair for transient Databento 504s on a single multi-year request.
The statistical gate is unchanged. Only the historical transport is made resilient:
- deterministic contiguous chunks,
- bounded retries with backoff,
- recursive split of a repeatedly failing chunk,
- exact concatenation followed by the original validator's own de-duplication.

The final holdout remains untouched because the wrapped validator still uses only
PHASE3_START_DATE..PHASE3_END_DATE (2022-09-01..2025-09-24).
"""

from __future__ import annotations

import time
from dataclasses import dataclass
from datetime import timedelta

import databento as db
import pandas as pd

import phase3_risk_gate_v2 as v2


_ORIGINAL_HISTORICAL = db.Historical
_CHUNK_DAYS = 90
_MIN_SPLIT_DAYS = 7
_MAX_ATTEMPTS = 4
_BACKOFF_SECONDS = (3, 10, 25, 45)


def _is_transient(exc: Exception) -> bool:
    text = str(exc).lower()
    markers = (
        "504",
        "503",
        "502",
        "500",
        "gateway timed out",
        "gateway timeout",
        "timed out",
        "timeout",
        "temporarily unavailable",
        "connection reset",
        "connection aborted",
    )
    return any(marker in text for marker in markers)


@dataclass
class _CombinedResult:
    frame: pd.DataFrame

    def to_df(self) -> pd.DataFrame:
        return self.frame


class _ResilientTimeseries:
    def __init__(self, inner):
        self._inner = inner

    def _fetch_once(self, kwargs, start_ts: pd.Timestamp, end_ts: pd.Timestamp) -> pd.DataFrame:
        request = dict(kwargs)
        request["start"] = start_ts.isoformat()
        request["end"] = end_ts.isoformat()
        data = self._inner.get_range(**request)
        return data.to_df()

    def _fetch_interval(self, kwargs, start_ts: pd.Timestamp, end_ts: pd.Timestamp, depth: int = 0) -> list[pd.DataFrame]:
        span_days = max(0.0, (end_ts - start_ts).total_seconds() / 86400.0)
        last_exc = None
        for attempt in range(1, _MAX_ATTEMPTS + 1):
            try:
                print(
                    f"DATABENTO_CHUNK_FETCH start={start_ts.isoformat()} end={end_ts.isoformat()} "
                    f"days={span_days:.1f} attempt={attempt}",
                    flush=True,
                )
                frame = self._fetch_once(kwargs, start_ts, end_ts)
                print(
                    f"DATABENTO_CHUNK_OK start={start_ts.date()} end={end_ts.date()} rows={len(frame)}",
                    flush=True,
                )
                return [frame]
            except Exception as exc:  # transport/API exception from Databento
                last_exc = exc
                if not _is_transient(exc):
                    raise
                print(
                    f"DATABENTO_CHUNK_TRANSIENT start={start_ts.date()} end={end_ts.date()} "
                    f"attempt={attempt} error={type(exc).__name__}: {exc}",
                    flush=True,
                )
                if attempt < _MAX_ATTEMPTS:
                    time.sleep(_BACKOFF_SECONDS[min(attempt - 1, len(_BACKOFF_SECONDS) - 1)])

        if span_days <= _MIN_SPLIT_DAYS:
            raise last_exc

        midpoint = start_ts + (end_ts - start_ts) / 2
        # Normalize the split to the nearest hour to keep request boundaries stable.
        midpoint = midpoint.floor("h")
        if midpoint <= start_ts or midpoint >= end_ts:
            raise last_exc

        print(
            f"DATABENTO_CHUNK_SPLIT start={start_ts.isoformat()} mid={midpoint.isoformat()} "
            f"end={end_ts.isoformat()} depth={depth}",
            flush=True,
        )
        left = self._fetch_interval(kwargs, start_ts, midpoint, depth + 1)
        right = self._fetch_interval(kwargs, midpoint, end_ts, depth + 1)
        return left + right

    def get_range(self, *args, **kwargs):
        if args:
            # The Phase 3 validator calls get_range with keyword arguments only.
            # Preserve compatibility by delegating any unexpected positional call.
            return self._inner.get_range(*args, **kwargs)

        if "start" not in kwargs or "end" not in kwargs:
            return self._inner.get_range(**kwargs)

        start_ts = pd.Timestamp(kwargs["start"])
        end_ts = pd.Timestamp(kwargs["end"])
        if start_ts.tzinfo is None:
            start_ts = start_ts.tz_localize("UTC")
        if end_ts.tzinfo is None:
            end_ts = end_ts.tz_localize("UTC")

        base_kwargs = dict(kwargs)
        base_kwargs.pop("start", None)
        base_kwargs.pop("end", None)

        frames: list[pd.DataFrame] = []
        cursor = start_ts
        while cursor < end_ts:
            chunk_end = min(cursor + pd.Timedelta(days=_CHUNK_DAYS), end_ts)
            frames.extend(self._fetch_interval(base_kwargs, cursor, chunk_end))
            cursor = chunk_end

        nonempty = [frame for frame in frames if frame is not None and not frame.empty]
        if not nonempty:
            return _CombinedResult(pd.DataFrame())

        combined = pd.concat(nonempty, axis=0).sort_index()
        # Boundary duplicates are harmless and will also be removed downstream;
        # remove them here to make transport evidence deterministic.
        combined = combined[~combined.index.duplicated(keep="first")]
        print(
            f"DATABENTO_RESILIENT_COMPLETE chunks={len(frames)} rows={len(combined)} "
            f"start={start_ts.isoformat()} end={end_ts.isoformat()}",
            flush=True,
        )
        return _CombinedResult(combined)


class _ResilientHistorical:
    def __init__(self, api_key: str):
        self._inner = _ORIGINAL_HISTORICAL(api_key)
        self.timeseries = _ResilientTimeseries(self._inner.timeseries)


def main():
    # Monkey-patch only the Historical transport used by the existing V2 validator.
    # No statistical thresholds, candidate definitions, or holdout dates are changed.
    v2.db.Historical = _ResilientHistorical
    v2.main()


if __name__ == "__main__":
    main()
