import json
import re
import sys
from pathlib import Path

PATTERNS = [
    (re.compile(r"^\s*DROP\s+TABLE\s+", re.I), "DROP_TABLE"),
    (re.compile(r"^\s*TRUNCATE\s+TABLE\s+", re.I), "TRUNCATE_TABLE"),
    (re.compile(r"^\s*DELETE\s+FROM\s+[\w.]+\s*(?!WHERE)", re.I), "DELETE_WITHOUT_WHERE"),
    (re.compile(r"^\s*ALTER\s+TABLE\s+[\w.]+\s+DROP\s+COLUMN\s+", re.I), "ALTER_DROP_COLUMN"),
]
COMMENT = re.compile(r"^\s*(--|#|//)")


def scan(root: Path):
    findings = []
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in {".sql", ".migrate", ".migration"}:
            continue
        for line_no, line in enumerate(path.read_text(encoding="utf-8", errors="replace").splitlines(), 1):
            if COMMENT.match(line):
                continue
            for pattern, operation in PATTERNS:
                if pattern.search(line):
                    findings.append({"file_path": str(path), "line_number": line_no, "operation_type": operation})
    return findings


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: contentflow_irreversible_scanner.py <deployment-artifact-dir>")
    print(json.dumps(scan(Path(sys.argv[1])), indent=2))
