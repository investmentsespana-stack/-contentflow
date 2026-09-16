"""Append-only experiment registry with a tamper-evident hash chain."""
from __future__ import annotations

from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from hashlib import sha256
import json
from pathlib import Path
from typing import Any, Dict, Iterable


@dataclass(frozen=True)
class TrialRecord:
    trial_id: str
    strategy_id: str
    code_version: str
    data_window: Dict[str, Any]
    config: Dict[str, Any]
    metrics: Dict[str, Any]
    status: str
    created_at_utc: str = field(default_factory=lambda: datetime.now(timezone.utc).isoformat())
    notes: str = ""


def _canonical(payload: Dict[str, Any]) -> str:
    return json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


class ExperimentRegistry:
    """JSONL registry that records every attempted strategy variation."""

    GENESIS = "0" * 64

    def __init__(self, path: str | Path) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)

    def _rows(self) -> list[dict[str, Any]]:
        if not self.path.exists():
            return []
        rows: list[dict[str, Any]] = []
        for line in self.path.read_text(encoding="utf-8").splitlines():
            if line.strip():
                rows.append(json.loads(line))
        return rows

    def append(self, record: TrialRecord) -> str:
        rows = self._rows()
        if any(row.get("trial_id") == record.trial_id for row in rows):
            raise ValueError(f"duplicate trial_id: {record.trial_id}")
        prev_hash = rows[-1]["record_hash"] if rows else self.GENESIS
        payload = asdict(record)
        payload["config_hash"] = sha256(_canonical(record.config).encode("utf-8")).hexdigest()
        payload["prev_hash"] = prev_hash
        record_hash = sha256(_canonical(payload).encode("utf-8")).hexdigest()
        payload["record_hash"] = record_hash
        with self.path.open("a", encoding="utf-8") as fh:
            fh.write(_canonical(payload) + "\n")
        return record_hash

    def records(self) -> Iterable[dict[str, Any]]:
        return tuple(self._rows())

    def verify_chain(self) -> bool:
        prev_hash = self.GENESIS
        seen: set[str] = set()
        for row in self._rows():
            trial_id = str(row.get("trial_id", ""))
            if not trial_id or trial_id in seen:
                return False
            seen.add(trial_id)
            if row.get("prev_hash") != prev_hash:
                return False
            claimed = row.get("record_hash")
            if not isinstance(claimed, str):
                return False
            payload = dict(row)
            payload.pop("record_hash", None)
            actual = sha256(_canonical(payload).encode("utf-8")).hexdigest()
            if actual != claimed:
                return False
            prev_hash = claimed
        return True
