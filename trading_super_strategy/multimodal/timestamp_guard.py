"""Point-in-time news visibility guard to prevent information leakage."""
from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable, Optional

import numpy as np


def _utc(dt: datetime) -> datetime:
    if dt.tzinfo is None:
        raise ValueError("timestamps must be timezone-aware")
    return dt.astimezone(timezone.utc)


@dataclass(frozen=True)
class NewsEvent:
    event_id: str
    headline: str
    published_at: datetime
    first_seen_at: datetime
    embedding: np.ndarray
    source: str = ""
    encoder_model_id: str = ""
    revision_of: Optional[str] = None

    @property
    def available_at(self) -> datetime:
        return max(_utc(self.published_at), _utc(self.first_seen_at))


class PointInTimeNewsGuard:
    """Returns only news that was actually available at decision time."""

    @staticmethod
    def visible(events: Iterable[NewsEvent], decision_time: datetime) -> tuple[NewsEvent, ...]:
        cutoff = _utc(decision_time)
        visible: list[NewsEvent] = []
        for event in events:
            _utc(event.published_at)
            _utc(event.first_seen_at)
            if event.available_at <= cutoff:
                visible.append(event)
        return tuple(sorted(visible, key=lambda e: (e.available_at, e.event_id)))
