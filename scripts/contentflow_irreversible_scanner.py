import json
import re
import sys
from pathlib import Path

SINGLE_LINE_PATTERNS = [
    (re.compile(r"^\s*DROP\s+TABLE\s+", re.I), "DROP_TABLE"),
    (re.compile(r"^\s*TRUNCATE\s+TABLE\s+", re.I), "TRUNCATE_TABLE"),
    (re.compile(r"^\s*ALTER\s+TABLE\s+[\w.]+\s+DROP\s+COLUMN\s+", re.I), "ALTER_DROP_COLUMN"),
]
DELETE_START = re.compile(r"^\s*DELETE\s+FROM\s+[\w.]+\b", re.I)
COMMENT = re.compile(r"^\s*(--|#|//)")


def scan_text(file_path: str, source: str):
    findings = []
    lines = source.splitlines()
    index = 0
    while index < len(lines):
        line = lines[index]
        if COMMENT.match(line):
            index += 1
            continue

        for pattern, operation in SINGLE_LINE_PATTERNS:
            if pattern.search(line):
                findings.append({"file_path": file_path, "line_number": index + 1, "operation_type": operation})

        if DELETE_START.search(line):
            start_line = index + 1
            statement_lines = [line]
            while ";" not in statement_lines[-1] and index + 1 < len(lines):
                index += 1
                statement_lines.append(lines[index])
            statement = "\n".join(statement_lines)
            statement = re.sub(r"--.*$", " ", statement, flags=re.M)
            if not re.search(r"\bWHERE\b", statement, re.I):
                findings.append({"file_path": file_path, "line_number": start_line, "operation_type": "DELETE_WITHOUT_WHERE"})

        index += 1
    return findings


def scan(root: Path):
    findings = []
    for path in root.rglob("*"):
        if not path.is_file() or path.suffix.lower() not in {".sql", ".migrate", ".migration"}:
            continue
        findings.extend(scan_text(str(path), path.read_text(encoding="utf-8", errors="replace")))
    return findings


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: contentflow_irreversible_scanner.py <deployment-artifact-dir>")
    print(json.dumps(scan(Path(sys.argv[1])), indent=2))
