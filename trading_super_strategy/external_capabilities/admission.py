from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any

ROOT = Path(__file__).resolve().parent
REGISTRY_PATH = ROOT / "registry.json"

ALLOWED_STATUSES = {
    "approved_runtime_research",
    "approved_ci_only",
    "approved_patterns_only",
    "approved_pilot_only",
}

SECRET_PATTERNS = (
    re.compile(r"\bgh[pousr]_[A-Za-z0-9]{20,}\b"),
    re.compile(r"\bgithub_pat_[A-Za-z0-9_]{20,}\b"),
    re.compile(r"\bsk-[A-Za-z0-9_-]{20,}\b"),
    re.compile(r"\bAKIA[0-9A-Z]{16}\b"),
    re.compile(r"\bBearer\s+[A-Za-z0-9._~+/-]+=*\b", re.I),
    re.compile(r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"),
)

FORBIDDEN_RUNTIME_PURPOSES = {"live_order_execution", "wallet_signing", "credential_export"}


def load_registry(path: Path = REGISTRY_PATH) -> dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8"))


def sanitize_text(value: str) -> str:
    out = value
    for pattern in SECRET_PATTERNS:
        out = pattern.sub("[REDACTED_SECRET]", out)
    return out


def validate_registry(data: dict[str, Any]) -> list[str]:
    errors: list[str] = []
    if data.get("schema_version") != 1:
        errors.append("schema_version must be 1")

    policy = data.get("policy") or {}
    if policy.get("live_money_default") is not False:
        errors.append("live_money_default must be false")
    if policy.get("fail_closed") is not True:
        errors.append("fail_closed must be true")
    if policy.get("arbitrary_shell_default") is not False:
        errors.append("arbitrary_shell_default must be false")

    seen: set[str] = set()
    for item in data.get("capabilities") or []:
        cid = str(item.get("id") or "")
        if not cid:
            errors.append("capability missing id")
            continue
        if cid in seen:
            errors.append(f"duplicate capability id: {cid}")
        seen.add(cid)

        status = item.get("status")
        if status not in ALLOWED_STATUSES:
            errors.append(f"{cid}: invalid status {status}")

        if item.get("live_money_allowed") is not False:
            errors.append(f"{cid}: live_money_allowed must be false")

        if item.get("arbitrary_shell_allowed") is not False:
            errors.append(f"{cid}: arbitrary_shell_allowed must be false")

        if item.get("purpose") in FORBIDDEN_RUNTIME_PURPOSES:
            errors.append(f"{cid}: forbidden purpose")

        if item.get("runtime_allowed"):
            if status != "approved_runtime_research":
                errors.append(f"{cid}: runtime_allowed requires approved_runtime_research")
            if not item.get("pinned_commit"):
                errors.append(f"{cid}: runtime capability requires pinned_commit")
            if item.get("package") and not item.get("pinned_version"):
                errors.append(f"{cid}: packaged runtime capability requires pinned_version")
            if item.get("package") and not item.get("package_sha256"):
                errors.append(f"{cid}: packaged runtime capability requires package_sha256")

        if "trading" in cid or "market" in str(item.get("purpose") or ""):
            if item.get("live_money_allowed") is not False:
                errors.append(f"{cid}: trading-adjacent capability must be research-only")

    return errors


def capability(data: dict[str, Any], capability_id: str) -> dict[str, Any]:
    for item in data.get("capabilities") or []:
        if item.get("id") == capability_id:
            return item
    raise KeyError(capability_id)


def is_operation_allowed(item: dict[str, Any], operation: str) -> bool:
    op = operation.strip().lower()
    if op in {"live", "order", "execute_order", "place_order", "broker_login", "wallet_sign"}:
        return False
    forbidden = {str(x).lower() for x in item.get("forbidden_scope") or []}
    if op in forbidden:
        return False
    if not item.get("runtime_allowed"):
        return False
    return True


def main() -> int:
    parser = argparse.ArgumentParser(description="Cygnus external capability admission gate")
    sub = parser.add_subparsers(dest="command", required=True)
    sub.add_parser("validate")
    p_sanitize = sub.add_parser("sanitize")
    p_sanitize.add_argument("text")
    p_allow = sub.add_parser("allow")
    p_allow.add_argument("capability_id")
    p_allow.add_argument("operation")
    args = parser.parse_args()

    data = load_registry()

    if args.command == "validate":
        errors = validate_registry(data)
        if errors:
            print(json.dumps({"ok": False, "errors": errors}, indent=2))
            return 1
        print(json.dumps({"ok": True, "capabilities": len(data.get("capabilities") or [])}, indent=2))
        return 0

    if args.command == "sanitize":
        print(sanitize_text(args.text))
        return 0

    if args.command == "allow":
        item = capability(data, args.capability_id)
        allowed = is_operation_allowed(item, args.operation)
        print(json.dumps({"capability": args.capability_id, "operation": args.operation, "allowed": allowed}))
        return 0 if allowed else 2

    return 2


if __name__ == "__main__":
    raise SystemExit(main())
