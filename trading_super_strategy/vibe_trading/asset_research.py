from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import time
from datetime import date
from pathlib import Path
from typing import Any

from fastmcp import Client

DEFAULT_MCP_URL = "http://127.0.0.1:8900/mcp"
ROOT = Path(r"C:\Cygnus\VibeTrading")
EVIDENCE_ROOT = ROOT / "evidence"

ASSETS: dict[str, dict[str, str]] = {
    "CL": {
        "target": "CL=F",
        "market": "CME WTI Crude Oil futures (CL)",
        "timeframe": "1D",
        "objective": "discover diverse systematic WTI crude-oil strategies with real-data backtests, explicit costs, OOS validation, and robustness checks",
    },
    "ES": {
        "target": "ES=F",
        "market": "CME E-mini S&P 500 futures (ES)",
        "timeframe": "1D",
        "objective": "discover diverse systematic E-mini S&P 500 strategies with real-data backtests, explicit costs, OOS validation, and robustness checks",
    },
    "NQ": {
        "target": "NQ=F",
        "market": "CME E-mini Nasdaq-100 futures (NQ)",
        "timeframe": "1D",
        "objective": "discover diverse systematic E-mini Nasdaq-100 strategies with real-data backtests, explicit costs, OOS validation, and robustness checks",
    },
    "GC": {
        "target": "GC=F",
        "market": "COMEX Gold futures (GC)",
        "timeframe": "1D",
        "objective": "discover diverse systematic gold-futures strategies with real-data backtests, explicit costs, OOS validation, and robustness checks",
    },
    "DXY": {
        "target": "DX-Y.NYB",
        "market": "US Dollar Index / ICE Dollar Index proxy (DXY/DX)",
        "timeframe": "1D",
        "objective": "discover diverse systematic US Dollar Index strategies with real-data backtests, explicit costs, OOS validation, and robustness checks",
    },
}
ALIASES = {"DX": "DXY"}

FORBIDDEN_TOOL_PREFIXES = ("trading_",)
FORBIDDEN_TOOL_NAMES = {"bash", "shell", "terminal", "exec", "run_command"}

def _text(result: Any) -> str:
    if result is None:
        return ""
    if isinstance(result, str):
        return result
    data = getattr(result, "data", None)
    if data is not None:
        try:
            return json.dumps(data, default=str, ensure_ascii=False)
        except Exception:
            return str(data)
    content = getattr(result, "content", None)
    if content is not None:
        out: list[str] = []
        try:
            for item in content:
                out.append(str(getattr(item, "text", None) or getattr(item, "data", None) or item))
            return "\n".join(out)
        except Exception:
            pass
    return str(result)

def _json_from_result(result: Any) -> Any:
    raw = _text(result).strip()
    candidates = [raw]
    if raw.startswith('"') and raw.endswith('"'):
        try:
            candidates.append(json.loads(raw))
        except Exception:
            pass
    for candidate in candidates:
        if isinstance(candidate, (dict, list)):
            return candidate
        if not isinstance(candidate, str):
            continue
        try:
            return json.loads(candidate)
        except Exception:
            continue
    return {"raw": raw}

def _run_id(payload: Any) -> str | None:
    if isinstance(payload, dict):
        for key in ("run_id", "id"):
            value = payload.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
        for value in payload.values():
            found = _run_id(value)
            if found:
                return found
    if isinstance(payload, list):
        for value in payload:
            found = _run_id(value)
            if found:
                return found
    return None

def _normalize_asset(value: str) -> str:
    asset = str(value or "").strip().upper()
    asset = ALIASES.get(asset, asset)
    if asset not in ASSETS:
        raise ValueError("ASSET_NOT_ALLOWED:" + asset)
    return asset

def _safe_run_id(value: str) -> str:
    run_id = str(value or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9._:-]{1,160}", run_id):
        raise ValueError("INVALID_RUN_ID")
    return run_id

async def _call(client: Client, name: str, args: dict[str, Any]) -> dict[str, Any]:
    try:
        result = await client.call_tool(name, args)
        ok = not bool(getattr(result, "is_error", False))
        parsed = _json_from_result(result)
        return {"ok": ok, "tool": name, "result": parsed, "excerpt": _text(result)[:5000]}
    except Exception as exc:
        return {"ok": False, "tool": name, "error": f"{type(exc).__name__}: {exc}"}

async def start(asset: str, mcp_url: str) -> dict[str, Any]:
    asset = _normalize_asset(asset)
    meta = ASSETS[asset]
    session_id = f"cygnus-{asset.lower()}-{int(time.time())}"
    objective = (
        f"{meta['objective']}. Research only. Do not place orders, do not select broker/live profiles, "
        "do not claim robustness without real backtest evidence, and prefer strategy diversity over near-clones."
    )
    criteria = [
        "Use real historical market data and record provenance.",
        "Generate at least five structurally different strategy hypotheses.",
        "Backtest multiple candidates with explicit execution costs.",
        "Use an out-of-sample or walk-forward split.",
        "Stress drawdown, parameter sensitivity, and regime dependence.",
        "Reject near-duplicate candidates and preserve only distinct survivors.",
        "No live trading, broker execution, or order placement.",
    ]

    evidence: dict[str, Any] = {
        "schema": "cygnus.vibe.asset_research.v1",
        "action": "start",
        "asset": asset,
        "target": meta["target"],
        "market": meta["market"],
        "timeframe": meta["timeframe"],
        "mode": "RESEARCH_ONLY",
        "live": False,
        "shell_tools": False,
        "broker_execution": False,
        "started_at_utc": time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()),
        "calls": [],
    }

    async with Client(mcp_url) as client:
        await client.ping()
        tools = await client.list_tools()
        names = sorted(str(getattr(t, "name", "") or "") for t in tools)
        evidence["mcp_tool_count"] = len(names)
        evidence["mcp_ping"] = "PASS"
        evidence["forbidden_mcp_tools_exposed"] = [
            name for name in names
            if name in FORBIDDEN_TOOL_NAMES or any(name.startswith(p) for p in FORBIDDEN_TOOL_PREFIXES)
        ]

        goal = await _call(client, "start_research_goal", {
            "objective": objective,
            "session_id": session_id,
            "criteria": criteria,
            "ui_summary": f"Cygnus {asset} strategy discovery",
            "protocol": "thesis_review",
            "risk_tier": "research_general",
            "turn_budget": 40,
            "time_budget_seconds": 7200,
        })
        evidence["calls"].append(goal)

        market_data = await _call(client, "get_market_data", {
            "codes": [meta["target"]],
            "start_date": "2020-01-01",
            "end_date": date.today().isoformat(),
            "source": "auto",
            "interval": meta["timeframe"],
            "max_rows": 250,
        })
        evidence["calls"].append(market_data)

        presets = await _call(client, "list_swarm_presets", {})
        evidence["calls"].append(presets)
        presets_text = json.dumps(presets.get("result"), ensure_ascii=False)
        if "cygnus_single_asset_strategy_desk" not in presets_text:
            evidence["status"] = "BLOCKED_PRESET_MISSING"
            evidence["reason"] = "cygnus_single_asset_strategy_desk not installed"
            return evidence

        swarm = await _call(client, "run_swarm", {
            "preset_name": "cygnus_single_asset_strategy_desk",
            "variables": {
                "target": meta["target"],
                "market": meta["market"],
                "timeframe": meta["timeframe"],
                "objective": objective,
            },
            "wait_seconds": 0,
            "start_only": True,
        })
        evidence["calls"].append(swarm)
        run_id = _run_id(swarm.get("result"))
        evidence["run_id"] = run_id
        evidence["status"] = "STARTED" if swarm.get("ok") and run_id else "FAILED_TO_START"
        return evidence

async def inspect(action: str, run_id: str, mcp_url: str) -> dict[str, Any]:
    run_id = _safe_run_id(run_id)
    tool = "get_swarm_status" if action == "status" else "get_run_result"
    async with Client(mcp_url) as client:
        await client.ping()
        call = await _call(client, tool, {"run_id": run_id})
    return {
        "schema": "cygnus.vibe.asset_research.v1",
        "action": action,
        "run_id": run_id,
        "mode": "RESEARCH_ONLY",
        "live": False,
        "shell_tools": False,
        "broker_execution": False,
        "call": call,
        "checked_at_utc": time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()),
    }

async def run(args: argparse.Namespace) -> int:
    EVIDENCE_ROOT.mkdir(parents=True, exist_ok=True)
    if args.action == "start":
        evidence = await start(args.asset, args.mcp_url)
        asset = _normalize_asset(args.asset)
        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        path = EVIDENCE_ROOT / f"asset-research-{asset.lower()}-{stamp}.json"
        path.write_text(json.dumps(evidence, indent=2, ensure_ascii=False, default=str), encoding="utf-8")
        print("VIBE_ASSET_RESEARCH_START")
        print(f"ASSET={asset}")
        print(f"STATUS={evidence.get('status')}")
        print(f"RUN_ID={evidence.get('run_id') or ''}")
        print("MODE=RESEARCH_ONLY")
        print("LIVE=false")
        print("SHELL_TOOLS=false")
        print("BROKER_EXECUTION=false")
        print(f"EVIDENCE={path}")
        return 0 if evidence.get("status") == "STARTED" else 2

    if not args.run_id:
        raise ValueError("RUN_ID_REQUIRED")
    evidence = await inspect(args.action, args.run_id, args.mcp_url)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    path = EVIDENCE_ROOT / f"asset-research-{args.action}-{stamp}.json"
    path.write_text(json.dumps(evidence, indent=2, ensure_ascii=False, default=str), encoding="utf-8")
    print("VIBE_ASSET_RESEARCH_CHECK")
    print(f"ACTION={args.action}")
    print(f"RUN_ID={args.run_id}")
    print("MODE=RESEARCH_ONLY")
    print("LIVE=false")
    print("SHELL_TOOLS=false")
    print("BROKER_EXECUTION=false")
    print(f"EVIDENCE={path}")
    return 0

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--action", choices=("start", "status", "result"), required=True)
    parser.add_argument("--asset", default="")
    parser.add_argument("--run-id", default="")
    parser.add_argument("--mcp-url", default=DEFAULT_MCP_URL)
    args = parser.parse_args()
    try:
        return asyncio.run(run(args))
    except Exception as exc:
        print(f"VIBE_ASSET_RESEARCH_FAIL: {type(exc).__name__}: {exc}", file=os.sys.stderr)
        return 1

if __name__ == "__main__":
    raise SystemExit(main())
