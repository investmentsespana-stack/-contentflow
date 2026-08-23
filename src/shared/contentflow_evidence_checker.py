from typing import Any, Mapping

EVIDENCE_FIELDS = (
    "extracted_text",
    "structured_data",
    "metadata",
    "annotations",
    "validation_results",
    "source_references",
)


def _nonempty(value: Any) -> bool:
    if value is None:
        return False
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        return bool(value.strip())
    if isinstance(value, (list, tuple, set, dict)):
        return len(value) > 0
    if isinstance(value, (int, float)):
        return value != 0
    return True


def has_evidence(review_output: Mapping[str, Any] | None) -> bool:
    if not review_output:
        return False
    return any(_nonempty(review_output.get(field)) for field in EVIDENCE_FIELDS)
