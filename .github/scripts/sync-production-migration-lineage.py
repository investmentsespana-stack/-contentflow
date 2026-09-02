#!/usr/bin/env python3
import json
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MIGRATIONS = ROOT / "supabase" / "migrations"
BACKUPS = ROOT / "backups"
SYNC_LIST = Path("/tmp/contentflow-synced-migrations.txt")

VERSION_RE = re.compile(r"^[0-9]{14}$")
NAME_RE = re.compile(r"^[A-Za-z0-9_]+$")
SENSITIVE_PATTERNS = [
    re.compile(r"BEGIN (?:RSA |OPENSSH |EC )?PRIVATE KEY", re.I),
    re.compile(r"postgres(?:ql)?://[^\s]+:[^\s@]+@", re.I),
    re.compile(r"eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,}"),
    re.compile(r"(?:api[_-]?key|secret[_-]?key|access[_-]?token)\s*=\s*'[^']{12,}'", re.I),
]


def baseline_head() -> str:
    heads = []
    if BACKUPS.exists():
        for manifest in BACKUPS.glob("*/manifest.json"):
            try:
                value = json.loads(manifest.read_text(encoding="utf-8")).get("database_migration_head", "")
            except Exception:
                continue
            if VERSION_RE.fullmatch(str(value)):
                heads.append(str(value))
    return max(heads) if heads else ""


def psql_json(db_args: list[str], query: str):
    cmd = ["psql", *db_args, "-Atqc", query]
    out = subprocess.check_output(cmd, text=True)
    return json.loads(out or "[]")


def existing_names() -> set[str]:
    names = set()
    if not MIGRATIONS.exists():
        return names
    for path in MIGRATIONS.glob("*.sql"):
        stem = path.stem
        if "_" in stem:
            _, name = stem.split("_", 1)
            names.add(name)
    return names


def safe_sql(statements: list[str]) -> str:
    rendered = []
    for raw in statements:
        if not isinstance(raw, str) or not raw.strip():
            raise RuntimeError("empty/non-string migration statement")
        for pattern in SENSITIVE_PATTERNS:
            if pattern.search(raw):
                raise RuntimeError("sensitive literal detected; refusing to sync migration source")
        stmt = raw.rstrip()
        if not stmt.endswith(";"):
            stmt += ";"
        rendered.append(stmt)
    return "\n\n".join(rendered) + "\n"


def main() -> int:
    db_args = sys.argv[1:]
    if not db_args:
        print("usage: sync-production-migration-lineage.py <psql connection args...>", file=sys.stderr)
        return 2

    prev_head = baseline_head()
    if not prev_head:
        print("No prior recovery manifest; nothing to reconcile before baseline establishment.")
        SYNC_LIST.write_text("", encoding="utf-8")
        return 0

    query = f"""
      select coalesce(json_agg(json_build_object(
        'version', version::text,
        'name', name,
        'statements', statements
      ) order by version), '[]'::json)::text
      from supabase_migrations.schema_migrations
      where version::text > '{prev_head}'
    """
    rows = psql_json(db_args, query)
    names = existing_names()
    MIGRATIONS.mkdir(parents=True, exist_ok=True)
    synced: list[str] = []

    for row in rows:
        version = str(row.get("version", ""))
        name = str(row.get("name", ""))
        statements = row.get("statements") or []
        if not VERSION_RE.fullmatch(version) or not NAME_RE.fullmatch(name):
            raise RuntimeError(f"unsafe migration identity version={version!r} name={name!r}")
        if name in names:
            continue
        path = MIGRATIONS / f"{version}_{name}.sql"
        path.write_text(
            "-- Reconciled from supabase_migrations.schema_migrations by recovery automation.\n"
            "-- Source: canonical production migration history; no credentials are emitted.\n\n"
            + safe_sql(statements),
            encoding="utf-8",
        )
        synced.append(str(path.relative_to(ROOT)))
        names.add(name)

    SYNC_LIST.write_text("".join(f"{p}\n" for p in synced), encoding="utf-8")
    print(f"MIGRATION_LINEAGE_RECONCILED baseline={prev_head} synced={len(synced)}")
    for path in synced:
        print(f"SYNCED_MIGRATION {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
