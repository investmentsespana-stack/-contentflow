from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from enum import Enum
from typing import Iterable, Optional

UTC = timezone.utc


class Freshness(str, Enum):
    FRESH = "fresh"
    STALE = "stale"
    MISSING = "missing"


@dataclass(frozen=True)
class MacroRelease:
    event_id: str
    release_time: datetime
    expected: float
    actual_initial: float
    revision_time: Optional[datetime] = None
    revised_value: Optional[float] = None
    severity: float = 0.0

    def __post_init__(self) -> None:
        if self.release_time.tzinfo is None:
            raise ValueError("release_time must be timezone-aware")
        if self.revision_time is not None and self.revision_time.tzinfo is None:
            raise ValueError("revision_time must be timezone-aware")


@dataclass(frozen=True)
class MacroSnapshot:
    event_id: str
    as_of: datetime
    release_time: Optional[datetime]
    expected: Optional[float]
    actual: Optional[float]
    surprise: Optional[float]
    freshness: Freshness
    confidence: float
    veto: bool


class PointInTimeMacroStore:
    def __init__(self, releases: Iterable[MacroRelease]):
        self._releases = tuple(releases)

    def snapshot(self, event_id: str, as_of: datetime, max_age: timedelta = timedelta(hours=24)) -> MacroSnapshot:
        if as_of.tzinfo is None:
            raise ValueError("as_of must be timezone-aware")
        eligible = [r for r in self._releases if r.event_id == event_id and r.release_time <= as_of]
        if not eligible:
            return MacroSnapshot(event_id, as_of, None, None, None, None, Freshness.MISSING, 0.0, True)
        release = max(eligible, key=lambda r: r.release_time)
        # Historical snapshots never substitute a later revised value.
        actual = release.actual_initial
        age = as_of - release.release_time
        freshness = Freshness.FRESH if age <= max_age else Freshness.STALE
        confidence = 1.0 if freshness is Freshness.FRESH else max(0.0, 1.0 - age.total_seconds() / timedelta(days=7).total_seconds())
        surprise = actual - release.expected
        veto = release.severity >= 1.0 or freshness is Freshness.MISSING
        return MacroSnapshot(event_id, as_of, release.release_time, release.expected, actual, surprise, freshness, confidence, veto)


def apply_macro_modifier(base_signal: float, snapshot: MacroSnapshot, max_weight: float = 0.30) -> float:
    if snapshot.veto:
        return 0.0
    if snapshot.freshness is Freshness.MISSING or snapshot.surprise is None:
        return base_signal * 0.5
    bounded = max(-max_weight, min(max_weight, snapshot.surprise * 0.10 * snapshot.confidence))
    modified = base_signal * (1.0 + bounded if base_signal >= 0 else 1.0 - bounded)
    return max(-1.0, min(1.0, modified))
