from __future__ import annotations

from typing import Mapping, Protocol, TypedDict


class ApprovalRecord(TypedDict):
    approval_id: str
    change_id: str
    payload_hash: str
    signature: str
    signer_key_id: str
    algorithm: str


class PlatformStore(Protocol):
    """Canonical storage boundary for approval validation and durable evidence."""

    def get_approval_record(self, approval_id: str) -> ApprovalRecord | None:
        """Fetch one approval record by immutable approval identifier."""
        ...

    def record_evidence(
        self,
        builder_run_id: int,
        event: Mapping[str, object],
    ) -> str:
        """Persist correlated evidence and return its durable evidence id."""
        ...
