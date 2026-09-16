from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable, Sequence

from .backtest_engine import Bar


@dataclass(frozen=True)
class ResampleStats:
    source_bars: int
    output_bars: int
    dropped_incomplete_buckets: int


def parse_ninjatrader_minute_lines(lines: Iterable[str]) -> list[Bar]:
    """Parse NinjaTrader minute export lines.

    Expected format per NinjaTrader export/import docs:
    yyyyMMdd HHmmss;open;high;low;close;volume

    NinjaTrader exports historical data in UTC and uses end-of-bar timestamps.
    """
    bars: list[Bar] = []
    previous_ts: datetime | None = None

    for lineno, raw in enumerate(lines, start=1):
        line = raw.strip()
        if not line:
            continue
        parts = line.split(";")
        if len(parts) != 6:
            raise ValueError(f"line {lineno}: expected 6 semicolon-separated fields")
        try:
            ts = datetime.strptime(parts[0], "%Y%m%d %H%M%S").replace(tzinfo=timezone.utc)
            open_, high, low, close, volume = map(float, parts[1:])
        except Exception as exc:
            raise ValueError(f"line {lineno}: invalid NinjaTrader minute record") from exc

        bar = Bar(
            timestamp=ts,
            open=open_,
            high=high,
            low=low,
            close=close,
            volume=volume,
        )
        reason = bar.validate()
        if reason is not None:
            raise ValueError(f"line {lineno}: {reason}")
        if previous_ts is not None and ts <= previous_ts:
            raise ValueError(f"line {lineno}: timestamps must be strictly increasing")
        previous_ts = ts
        bars.append(bar)

    if not bars:
        raise ValueError("no valid NinjaTrader minute bars found")
    return bars


def parse_ninjatrader_minute_text(text: str) -> list[Bar]:
    return parse_ninjatrader_minute_lines(text.splitlines())


def _bucket_end_epoch(timestamp: datetime, minutes: int) -> int:
    if timestamp.tzinfo is None:
        raise ValueError("timestamps must be timezone-aware")
    interval = minutes * 60
    epoch = int(timestamp.timestamp())
    # NinjaTrader minute exports use end-of-bar timestamps. An exact boundary
    # belongs to that boundary; otherwise round up to the next interval end.
    return ((epoch - 1) // interval + 1) * interval


def resample_minute_bars(
    bars: Sequence[Bar],
    *,
    minutes: int = 15,
    require_complete: bool = True,
) -> tuple[list[Bar], ResampleStats]:
    if minutes < 1:
        raise ValueError("minutes must be >= 1")
    if not bars:
        raise ValueError("bars must not be empty")

    grouped: dict[int, list[Bar]] = {}
    previous_ts: datetime | None = None
    for bar in bars:
        if bar.timestamp.tzinfo is None:
            raise ValueError("all bars must have timezone-aware timestamps")
        if previous_ts is not None and bar.timestamp <= previous_ts:
            raise ValueError("bars must be strictly increasing")
        previous_ts = bar.timestamp
        grouped.setdefault(_bucket_end_epoch(bar.timestamp, minutes), []).append(bar)

    output: list[Bar] = []
    dropped = 0
    expected_seconds = 60

    for bucket_end in sorted(grouped):
        chunk = grouped[bucket_end]
        complete = len(chunk) == minutes
        if complete:
            for i in range(1, len(chunk)):
                delta = int((chunk[i].timestamp - chunk[i - 1].timestamp).total_seconds())
                if delta != expected_seconds:
                    complete = False
                    break

        if require_complete and not complete:
            dropped += 1
            continue

        output.append(
            Bar(
                timestamp=datetime.fromtimestamp(bucket_end, tz=timezone.utc),
                open=chunk[0].open,
                high=max(b.high for b in chunk),
                low=min(b.low for b in chunk),
                close=chunk[-1].close,
                volume=sum(b.volume for b in chunk),
            )
        )

    if not output:
        raise ValueError("resampling produced no complete bars")

    return output, ResampleStats(
        source_bars=len(bars),
        output_bars=len(output),
        dropped_incomplete_buckets=dropped,
    )
