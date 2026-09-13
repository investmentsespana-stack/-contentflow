from __future__ import annotations

from dataclasses import dataclass
from typing import Iterable, Sequence


@dataclass(frozen=True)
class BookEvent:
    ts_event_ns: int
    ts_recv_ns: int
    bid_px: float
    ask_px: float
    bid_sz: float
    ask_sz: float
    action: str = "update"  # add, cancel, trade, update


@dataclass(frozen=True)
class MicrostructureSnapshot:
    as_of_ns: int
    spread: float
    book_imbalance: float
    queue_pressure: float
    add_count: int
    cancel_count: int
    trade_count: int
    inferred_label: str = "measured_pattern_not_participant_intent"


class DataUnsafeError(ValueError):
    pass


class PointInTimeMicrostructureEngine:
    """Deterministic, fail-closed point-in-time MBP/MBO feature engine.

    The engine consumes only events whose exchange event timestamp is at or
    before `as_of_ns`. Receive timestamps must not precede event timestamps.
    It measures visible book state and event counts; it never claims trader
    identity or intent.
    """

    VALID_ACTIONS = {"add", "cancel", "trade", "update"}

    @staticmethod
    def _validate(event: BookEvent) -> None:
        if event.ts_event_ns < 0 or event.ts_recv_ns < 0:
            raise DataUnsafeError("negative_timestamp")
        if event.ts_recv_ns < event.ts_event_ns:
            raise DataUnsafeError("receive_before_event")
        if event.bid_px <= 0 or event.ask_px <= 0:
            raise DataUnsafeError("non_positive_price")
        if event.ask_px < event.bid_px:
            raise DataUnsafeError("crossed_book")
        if event.bid_sz < 0 or event.ask_sz < 0:
            raise DataUnsafeError("negative_size")
        if event.action not in PointInTimeMicrostructureEngine.VALID_ACTIONS:
            raise DataUnsafeError("unknown_action")

    def snapshot(self, events: Sequence[BookEvent] | Iterable[BookEvent], as_of_ns: int) -> MicrostructureSnapshot:
        if as_of_ns < 0:
            raise DataUnsafeError("negative_as_of")

        visible = []
        add_count = cancel_count = trade_count = 0
        for event in events:
            self._validate(event)
            if event.ts_event_ns > as_of_ns:
                continue
            visible.append(event)
            if event.action == "add":
                add_count += 1
            elif event.action == "cancel":
                cancel_count += 1
            elif event.action == "trade":
                trade_count += 1

        if not visible:
            raise DataUnsafeError("no_point_in_time_events")

        latest = max(visible, key=lambda e: (e.ts_event_ns, e.ts_recv_ns))
        spread = latest.ask_px - latest.bid_px
        denom = latest.bid_sz + latest.ask_sz
        imbalance = 0.0 if denom == 0 else (latest.bid_sz - latest.ask_sz) / denom
        queue_pressure = 0.0 if latest.ask_sz == 0 else latest.bid_sz / latest.ask_sz

        return MicrostructureSnapshot(
            as_of_ns=as_of_ns,
            spread=spread,
            book_imbalance=imbalance,
            queue_pressure=queue_pressure,
            add_count=add_count,
            cancel_count=cancel_count,
            trade_count=trade_count,
        )
