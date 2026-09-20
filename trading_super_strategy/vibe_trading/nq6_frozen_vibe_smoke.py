#!/usr/bin/env python3
"""
Cygnus NQ6 -> Vibe-Trading read-only smoke test.

Purpose:
- Use the six already-frozen NQ CFD H1 StrategyQuant .sqx artifacts.
- Never start/stop/invoke StrategyQuant.
- Verify exact frozen identity (name, size, CRC32) before use.
- Extract .sqx as ZIP into Vibe's allowed local upload root.
- Connect only to the local Vibe MCP endpoint.
- Call read-only MCP tools (list_skills, read_file).
- Fail closed if shell/command execution tools are exposed.
- Produce deterministic JSON evidence.

This is an integration smoke test, NOT strategy re-optimization and NOT live trading.
"""
from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import os
import sys
import time
import zipfile
import zlib
from dataclasses import dataclass, asdict
from pathlib import Path
from typing import Any

VIBE_VERSION_EXPECTED = "0.1.15"
DEFAULT_MCP_URL = "http://127.0.0.1:8900/mcp"

EXPECTED = [
    ("Strategy 2.36.115.sqx", 232846, 0xB4382EBB),
    ("Strategy 2.37.117.sqx", 232477, 0xCAF10493),
    ("Strategy 2.37.137.sqx", 232833, 0xE282F201),
    ("Strategy 2.38.122.sqx", 232663, 0xC8019DCC),
    ("Strategy 2.38.155.sqx", 232487, 0x88D67CDB),
    ("Strategy 2.38.177.sqx", 231631, 0x95FAA90A),
]

PROJECT_ROOT_CANDIDATES = [
    Path(r"C:\Users\Administrator\Downloads\SQX_142_win_20250327\user\projects\NQ CFD H1 - Dukascopy"),
    Path(r"C:\OI\user\projects\NQ CFD H1 - Dukascopy"),
]

DANGEROUS_TOOL_NAMES = {
    "bash",
    "background_run",
    "cancel_background",
    "run_background",
    "shell",
    "powershell",
    "cmd",
    "terminal",
}

@dataclass
class StrategyEvidence:
    name: str
    path: str
    size: int
    crc32: str
    sha256: str
    zip_valid: bool
    xml_files: list[str]
    vibe_read_file: str
    vibe_read_ok: bool


def file_crc32(path: Path) -> int:
    crc = 0
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            crc = zlib.crc32(chunk, crc)
    return crc & 0xFFFFFFFF


def file_sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def find_frozen_file(name: str, size: int, crc: int) -> Path:
    matches: list[Path] = []
    for root in PROJECT_ROOT_CANDIDATES:
        if not root.exists():
            continue
        for p in root.rglob(name):
            if not p.is_file():
                continue
            try:
                if p.stat().st_size == size and file_crc32(p) == crc:
                    matches.append(p)
            except OSError:
                continue
    if len(matches) != 1:
        raise RuntimeError(
            f"FROZEN_IDENTITY_FAIL {name}: expected exactly 1 exact match, found {len(matches)}"
        )
    return matches[0]


def safe_extract_sqx(src: Path, dest: Path) -> list[Path]:
    if not zipfile.is_zipfile(src):
        raise RuntimeError(f"SQX_NOT_ZIP {src}")
    dest.mkdir(parents=True, exist_ok=True)
    root = dest.resolve()
    out: list[Path] = []
    with zipfile.ZipFile(src) as zf:
        for info in zf.infolist():
            candidate = (dest / info.filename).resolve()
            if root not in candidate.parents and candidate != root:
                raise RuntimeError(f"ZIP_PATH_TRAVERSAL_BLOCKED {src.name}:{info.filename}")
            zf.extract(info, dest)
            if not info.is_dir():
                out.append(candidate)
    return out


def tool_name(t: Any) -> str:
    return str(getattr(t, "name", "") or "")


def tool_schema(t: Any) -> dict[str, Any]:
    for attr in ("inputSchema", "input_schema"):
        v = getattr(t, attr, None)
        if isinstance(v, dict):
            return v
    return {}


def result_to_text(result: Any) -> str:
    if result is None:
        return ""
    if isinstance(result, str):
        return result
    if isinstance(result, (dict, list, tuple)):
        try:
            return json.dumps(result, default=str, ensure_ascii=False)
        except Exception:
            return str(result)
    data = getattr(result, "data", None)
    if data is not None:
        try:
            return json.dumps(data, default=str, ensure_ascii=False)
        except Exception:
            return str(data)
    content = getattr(result, "content", None)
    if content is not None:
        try:
            parts = []
            for item in content:
                parts.append(str(getattr(item, "text", None) or getattr(item, "data", None) or item))
            return "\n".join(parts)
        except Exception:
            pass
    return str(result)


async def mcp_probe(url: str, read_paths: list[Path], evidence: dict[str, Any]) -> None:
    from fastmcp import Client

    async with Client(url) as client:
        await client.ping()
        tools = await client.list_tools()
        names = [tool_name(t) for t in tools]
        evidence["mcp"] = {
            "url": url,
            "ping": "PASS",
            "tool_count": len(names),
            "tools": names,
        }

        dangerous = [
            n for n in names
            if n.lower() in DANGEROUS_TOOL_NAMES
            or "shell" in n.lower()
            or "terminal" in n.lower()
        ]
        # Match actual OS-process/RCE tools. Do not reject research-data tools
        # such as qveris_execute merely because their name contains "execute".
        if dangerous:
            raise RuntimeError("SHELL_TOOL_EXPOSURE_FAIL " + ",".join(dangerous))

        by_name = {tool_name(t): t for t in tools}
        if "list_skills" not in by_name:
            raise RuntimeError("MCP_TOOL_MISSING list_skills")
        skills = await client.call_tool("list_skills", {})
        evidence["mcp"]["list_skills_ok"] = True
        evidence["mcp"]["list_skills_excerpt"] = result_to_text(skills)[:2000]

        if not read_paths:
            return

        if "read_file" not in by_name:
            raise RuntimeError("MCP_TOOL_MISSING read_file")

        schema = tool_schema(by_name["read_file"])
        props = schema.get("properties", {}) if isinstance(schema, dict) else {}
        required = set(schema.get("required", []) if isinstance(schema, dict) else [])
        path_key = next((k for k in ("path", "file_path", "filepath", "filename") if k in props), None)
        if not path_key:
            raise RuntimeError(f"READ_FILE_SCHEMA_UNSUPPORTED {json.dumps(schema, default=str)[:1000]}")

        reads: list[dict[str, Any]] = []
        for p in read_paths:
            args: dict[str, Any] = {path_key: str(p)}
            for k in required:
                if k in args:
                    continue
                if k == "offset":
                    args[k] = 0
                elif k == "limit":
                    args[k] = 4000
                elif k == "encoding":
                    args[k] = "utf-8"
                else:
                    raise RuntimeError(f"READ_FILE_REQUIRED_ARG_UNSUPPORTED {k}")
            result = await client.call_tool("read_file", args)
            text = result_to_text(result)
            is_error = bool(getattr(result, "is_error", False))
            ok = (not is_error) and len(text.strip()) > 0
            reads.append({"path": str(p), "ok": ok, "excerpt": text[:1200]})
            if not ok:
                raise RuntimeError(f"VIBE_READ_FILE_FAIL {p}")
        evidence["mcp"]["read_file_results"] = reads


def choose_strategy_xml(files: list[Path]) -> Path:
    xmls = [p for p in files if p.suffix.lower() == ".xml" and p.is_file()]
    if not xmls:
        raise RuntimeError("SQX_XML_MISSING")
    # Prefer the largest XML, which normally contains the richest ResultsGroup/strategy payload.
    return max(xmls, key=lambda p: p.stat().st_size)


async def run(args: argparse.Namespace) -> int:
    ts = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    evidence: dict[str, Any] = {
        "schema": "cygnus.vibe.nq6.frozen.smoke.v1",
        "created_at_utc": ts,
        "mode": "RESEARCH_ONLY",
        "live": False,
        "shell_tools": False,
        "sqx_invoked": False,
        "vibe_version_expected": VIBE_VERSION_EXPECTED,
        "project": "NQ CFD H1 - Dukascopy",
        "purpose": "read-only E2E ingestion smoke test of six frozen SQX strategies",
    }

    if args.probe_only:
        await mcp_probe(args.mcp_url, [], evidence)
        print("VIBE_MCP_PROBE_PASS")
        print(f"MCP_TOOLS={evidence['mcp']['tool_count']}")
        print("MODE=RESEARCH_ONLY")
        print("LIVE=false")
        print("SQX_INVOKED=false")
        return 0

    upload_root = Path(r"C:\\Cygnus\\VibeTrading\\data") / "cygnus-nq6-frozen-smoke" / ts
    upload_root.mkdir(parents=True, exist_ok=True)

    strategy_evidence: list[StrategyEvidence] = []
    read_paths: list[Path] = []

    for name, expected_size, expected_crc in EXPECTED:
        src = find_frozen_file(name, expected_size, expected_crc)
        dest = upload_root / src.stem
        extracted = safe_extract_sqx(src, dest)
        xmls = [p for p in extracted if p.suffix.lower() == ".xml" and p.is_file()]
        chosen = choose_strategy_xml(extracted)
        read_paths.append(chosen)
        strategy_evidence.append(StrategyEvidence(
            name=name,
            path=str(src),
            size=src.stat().st_size,
            crc32=f"{file_crc32(src):08x}",
            sha256=file_sha256(src),
            zip_valid=True,
            xml_files=[str(p) for p in xmls],
            vibe_read_file=str(chosen),
            vibe_read_ok=False,
        ))

    evidence["strategies"] = [asdict(s) for s in strategy_evidence]
    await mcp_probe(args.mcp_url, read_paths, evidence)

    read_map = {r["path"]: r["ok"] for r in evidence["mcp"].get("read_file_results", [])}
    for s in evidence["strategies"]:
        s["vibe_read_ok"] = bool(read_map.get(s["vibe_read_file"]))

    if len(evidence["strategies"]) != 6 or not all(s["vibe_read_ok"] for s in evidence["strategies"]):
        raise RuntimeError("NQ6_INGESTION_NOT_COMPLETE")

    evidence_dir = Path(r"C:\Cygnus\VibeTrading\evidence")
    evidence_dir.mkdir(parents=True, exist_ok=True)
    evidence_path = evidence_dir / f"nq6-vibe-frozen-smoke-{ts}.json"
    evidence_path.write_text(json.dumps(evidence, ensure_ascii=False, indent=2), encoding="utf-8")

    print("VIBE_NQ6_SMOKE_PASS")
    print("STRATEGIES=6")
    print("IDENTITY_MATCH=6/6")
    print("VIBE_READ_FILE=6/6")
    print(f"MCP_TOOLS={evidence['mcp']['tool_count']}")
    print("MODE=RESEARCH_ONLY")
    print("LIVE=false")
    print("SHELL_TOOLS=false")
    print("SQX_INVOKED=false")
    print(f"EVIDENCE={evidence_path}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mcp-url", default=DEFAULT_MCP_URL)
    parser.add_argument("--probe-only", action="store_true")
    args = parser.parse_args()
    try:
        return asyncio.run(run(args))
    except Exception as exc:
        print(f"VIBE_NQ6_SMOKE_FAIL: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
