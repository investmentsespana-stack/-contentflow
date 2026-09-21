from __future__ import annotations

import argparse
import asyncio
import importlib.metadata
import json
import os
import re
import time
from pathlib import Path
from typing import Any

from fastmcp import Client

ROOT = Path(r"C:\Cygnus\VibeTrading")
STATE_ROOT = ROOT / "state"
EVIDENCE_ROOT = ROOT / "evidence"
DEFAULT_MCP_URL = "http://127.0.0.1:8900/mcp"

# Keep the Vibe worker runtime, OAuth store, swarm store and this control script
# on the same canonical runtime root.
os.environ["VIBE_TRADING_HOME"] = str(STATE_ROOT)
# Force the native Vibe provider/model inside this fixed research process.
# The long-running Bridge may carry stale environment variables from an older
# Vibe install; explicit assignment here prevents them from overriding the
# canonical Vibe configuration.
os.environ["LANGCHAIN_PROVIDER"] = "openai-codex"
os.environ["LANGCHAIN_MODEL_NAME"] = "openai-codex/gpt-5.4"
os.environ["VIBE_TRADING_ENABLE_SHELL_TOOLS"] = "0"
os.environ["CYGNUS_RESEARCH_ONLY"] = "1"

ASSETS: dict[str, dict[str, str]] = {
    "CL": {
        "target": "CL=F",
        "market": "WTI crude oil futures, NYMEX/CME",
        "preset": "cygnus_futures_strategy_lab",
        "goal": "discover diverse systematic CL strategies with real-data backtests, OOS validation and robustness evidence",
    },
    "ES": {
        "target": "ES=F",
        "market": "E-mini S&P 500 futures, CME",
        "preset": "cygnus_futures_strategy_lab",
        "goal": "discover diverse systematic ES strategies with real-data backtests, OOS validation and robustness evidence",
    },
    "NQ": {
        "target": "NQ=F",
        "market": "E-mini Nasdaq-100 futures, CME",
        "preset": "cygnus_futures_strategy_lab",
        "goal": "discover diverse systematic NQ strategies with real-data backtests, OOS validation and robustness evidence",
    },
    "GC": {
        "target": "GC=F",
        "market": "Gold futures, COMEX",
        "preset": "cygnus_futures_strategy_lab",
        "goal": "discover diverse systematic GC strategies with real-data backtests, OOS validation and robustness evidence",
    },
    "DXY": {
        "target": "DX-Y.NYB",
        "market": "U.S. Dollar Index cash/index proxy from Yahoo; DX futures are not treated as execution-ready until contract specs are explicitly modeled",
        "preset": "cygnus_dxy_macro_lab",
        "goal": "research DXY as a macro/regime factor, derive systematic hypotheses, and test only evidence-backed proxy strategies without pretending the cash index is an executable futures contract",
    },
}
ALIASES = {"DX": "DXY"}
TERMINAL_SWARM_STATES = {"completed", "failed", "cancelled", "canceled", "blocked", "error"}
REQUIRED_MCP_TOOLS = {
    "get_market_data",
    "technical_indicators",
    "backtest",
    "quantlib_call",
    "load_skill",
    "read_file",
    "write_file",
    "run_swarm",
    "get_swarm_status",
    "get_run_result",
}
FORBIDDEN_MCP_TOOLS = {"bash", "background_run", "cancel_background"}


def _json_layers(value: Any, max_layers: int = 8) -> Any:
    current = value
    for _ in range(max_layers):
        if isinstance(current, (dict, list)):
            return current
        if not isinstance(current, str):
            return current
        stripped = current.strip()
        if not stripped:
            return stripped
        try:
            decoded = json.loads(stripped)
        except Exception:
            return current
        if decoded == current:
            return decoded
        current = decoded
    return current


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
        try:
            return "\n".join(
                str(getattr(item, "text", None) or getattr(item, "data", None) or item)
                for item in content
            )
        except Exception:
            pass
    return str(result)


async def _call(client: Client, name: str, args: dict[str, Any]) -> dict[str, Any]:
    try:
        result = await client.call_tool(name, args)
        raw = _text(result)
        return {
            "ok": not bool(getattr(result, "is_error", False)),
            "tool": name,
            "result": _json_layers(raw),
            "excerpt": raw[:6000],
        }
    except Exception as exc:
        return {"ok": False, "tool": name, "error": f"{type(exc).__name__}: {exc}"}


def _extract_run_id(value: Any) -> str | None:
    value = _json_layers(value)
    if isinstance(value, dict):
        for key in ("run_id", "id"):
            candidate = value.get(key)
            if isinstance(candidate, str) and re.fullmatch(r"[A-Za-z0-9._:-]{1,160}", candidate.strip()):
                return candidate.strip()
        for child in value.values():
            found = _extract_run_id(child)
            if found:
                return found
    elif isinstance(value, list):
        for child in value:
            found = _extract_run_id(child)
            if found:
                return found
    elif isinstance(value, str):
        m = re.search(r"swarm-\d{8}-\d{6}-[A-Za-z0-9]+", value)
        if m:
            return m.group(0)
    return None


def _normalize_asset(value: str) -> str:
    asset = str(value or "").strip().upper()
    asset = ALIASES.get(asset, asset)
    if asset not in ASSETS:
        raise ValueError(f"ASSET_NOT_ALLOWED:{asset}")
    return asset


def _safe_run_id(value: str) -> str:
    run_id = str(value or "").strip()
    if not re.fullmatch(r"[A-Za-z0-9._:-]{1,160}", run_id):
        raise ValueError("INVALID_RUN_ID")
    return run_id


def _provider_snapshot() -> dict[str, Any]:
    from src.config.accessor import get_env_config, reset_env_config
    from src.providers.openai_codex import get_openai_codex_login_status

    reset_env_config()
    cfg = get_env_config()
    provider = cfg.llm.langchain_provider.strip()
    model = cfg.llm.langchain_model_name.strip()
    token = get_openai_codex_login_status() if provider.lower().replace("_", "-") == "openai-codex" else None
    return {
        "provider": provider,
        "model": model,
        "oauth_ready": bool(token),
        "oauth_account_present": bool(getattr(token, "account_id", None)) if token else False,
    }


def _local_inventory() -> dict[str, Any]:
    from src.agent.skills import SkillsLoader
    from src.swarm.presets import inspect_preset, list_presets

    skills = SkillsLoader().skills
    presets = list_presets()
    names: list[str] = []
    if isinstance(presets, list):
        for p in presets:
            if isinstance(p, str):
                names.append(p)
            elif isinstance(p, dict):
                n = p.get("name")
                if isinstance(n, str):
                    names.append(n)
    required_presets = [
        "cygnus_native_smoke",
        "cygnus_futures_strategy_lab",
        "cygnus_dxy_macro_lab",
    ]
    inspected = {name: inspect_preset(name) for name in required_presets}
    return {
        "skill_count": len(skills),
        "preset_count": len(names),
        "required_presets": inspected,
    }


def _llm_smoke() -> dict[str, Any]:
    from src.providers.chat import ChatLLM

    llm = ChatLLM()
    try:
        response = llm.chat(
            [{"role": "user", "content": "Reply with exactly VIBE_NATIVE_LLM_OK"}],
            timeout=45,
        )
        content = str(getattr(response, "content", "") or "").strip()
        return {"ok": "VIBE_NATIVE_LLM_OK" in content, "content": content[:500]}
    finally:
        llm.close()


def _rows_for_symbol(payload: Any, symbol: str) -> int:
    data = _json_layers(payload)
    if not isinstance(data, dict):
        return 0
    rows = data.get(symbol)
    return len(rows) if isinstance(rows, list) else 0


async def _native_agent_smoke(client: Client) -> dict[str, Any]:
    start = await _call(
        client,
        "run_swarm",
        {
            "preset_name": "cygnus_native_smoke",
            "variables": {"target": "ES=F"},
            "wait_seconds": 0,
            "start_only": True,
        },
    )
    run_id = _extract_run_id(start.get("result"))
    if not start.get("ok") or not run_id:
        return {"ok": False, "start": start, "reason": "no_run_id"}

    deadline = time.monotonic() + 120
    latest: dict[str, Any] = {}
    while time.monotonic() < deadline:
        latest = await _call(client, "get_swarm_status", {"run_id": run_id})
        state_blob = json.dumps(latest.get("result"), ensure_ascii=False, default=str).lower()
        if any(f'"status": "{s}"' in state_blob or f'"state": "{s}"' in state_blob for s in TERMINAL_SWARM_STATES):
            break
        await asyncio.sleep(2)

    final = await _call(client, "get_run_result", {"run_id": run_id})
    final_blob = json.dumps(final.get("result"), ensure_ascii=False, default=str).lower()
    failed = any(x in final_blob for x in ['"status": "failed"', '"state": "failed"', "langchain_model_name is not set"])
    return {
        "ok": bool(final.get("ok")) and not failed,
        "run_id": run_id,
        "status": latest,
        "result": final,
    }


async def full_health(mcp_url: str) -> dict[str, Any]:
    evidence: dict[str, Any] = {
        "schema": "cygnus.vibe.full_health.v1",
        "mode": "RESEARCH_ONLY",
        "live": False,
        "shell_tools": False,
        "broker_execution": False,
        "checked_at_utc": time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()),
        "checks": {},
    }

    try:
        evidence["checks"]["package_version"] = {
            "ok": importlib.metadata.version("vibe-trading-ai") == "0.1.15",
            "value": importlib.metadata.version("vibe-trading-ai"),
        }
    except Exception as exc:
        evidence["checks"]["package_version"] = {"ok": False, "error": str(exc)}

    try:
        provider = _provider_snapshot()
        evidence["checks"]["provider"] = {
            "ok": (
                provider.get("provider", "").lower().replace("_", "-") == "openai-codex"
                and provider.get("model") == "openai-codex/gpt-5.4"
                and provider.get("oauth_ready") is True
            ),
            **provider,
        }
    except Exception as exc:
        evidence["checks"]["provider"] = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

    try:
        inventory = _local_inventory()
        preset_ok = all(
            isinstance(v, dict) and v.get("valid") is True
            for v in inventory.get("required_presets", {}).values()
        )
        evidence["checks"]["inventory"] = {
            "ok": inventory.get("skill_count", 0) >= 80 and preset_ok,
            **inventory,
        }
    except Exception as exc:
        evidence["checks"]["inventory"] = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

    try:
        evidence["checks"]["llm_smoke"] = _llm_smoke()
    except Exception as exc:
        evidence["checks"]["llm_smoke"] = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

    try:
        async with Client(mcp_url) as client:
            await client.ping()
            tools = await client.list_tools()
            tool_names = sorted(str(getattr(t, "name", "") or "") for t in tools)
            missing = sorted(REQUIRED_MCP_TOOLS - set(tool_names))
            forbidden = sorted(FORBIDDEN_MCP_TOOLS & set(tool_names))
            evidence["checks"]["mcp"] = {
                "ok": not missing and not forbidden,
                "tool_count": len(tool_names),
                "missing_required": missing,
                "forbidden_exposed": forbidden,
            }

            futures_data = await _call(
                client,
                "get_market_data",
                {
                    "codes": ["CL=F", "ES=F", "NQ=F", "GC=F"],
                    "start_date": "2026-08-01",
                    "end_date": "2026-09-20",
                    "source": "auto",
                    "interval": "1D",
                    "max_rows": 20,
                },
            )
            dxy_data = await _call(
                client,
                "get_market_data",
                {
                    "codes": ["DX-Y.NYB"],
                    "start_date": "2026-08-01",
                    "end_date": "2026-09-20",
                    "source": "yahoo",
                    "interval": "1D",
                    "max_rows": 20,
                },
            )
            rows = {
                symbol: _rows_for_symbol(futures_data.get("result"), symbol)
                for symbol in ("CL=F", "ES=F", "NQ=F", "GC=F")
            }
            rows["DX-Y.NYB"] = _rows_for_symbol(dxy_data.get("result"), "DX-Y.NYB")
            evidence["checks"]["market_data"] = {
                "ok": all(v > 0 for v in rows.values()),
                "rows": rows,
                "futures_call": futures_data,
                "dxy_call": dxy_data,
            }

            evidence["checks"]["native_agent_smoke"] = await _native_agent_smoke(client)
    except Exception as exc:
        evidence["checks"]["mcp_or_agent"] = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

    checks = evidence["checks"]
    evidence["status"] = "PASS" if checks and all(bool(v.get("ok")) for v in checks.values()) else "FAIL"
    return evidence


async def start(asset: str, mcp_url: str) -> dict[str, Any]:
    asset = _normalize_asset(asset)
    meta = ASSETS[asset]

    provider = _provider_snapshot()
    if not (
        provider.get("provider", "").lower().replace("_", "-") == "openai-codex"
        and provider.get("model") == "openai-codex/gpt-5.4"
        and provider.get("oauth_ready") is True
    ):
        return {
            "schema": "cygnus.vibe.asset_research.native.v1",
            "asset": asset,
            "status": "BLOCKED_PROVIDER_NOT_READY",
            "provider": provider,
            "mode": "RESEARCH_ONLY",
            "live": False,
            "shell_tools": False,
            "broker_execution": False,
        }

    async with Client(mcp_url) as client:
        await client.ping()
        payload: dict[str, Any]
        if asset == "DXY":
            payload = {
                "preset_name": meta["preset"],
                "variables": {
                    "target": meta["target"],
                    "goal": meta["goal"],
                    "timeframe": "1-6 months",
                },
                "wait_seconds": 0,
                "start_only": True,
            }
        else:
            payload = {
                "preset_name": meta["preset"],
                "variables": {
                    "target": meta["target"],
                    "market": meta["market"],
                    "goal": meta["goal"],
                },
                "wait_seconds": 0,
                "start_only": True,
            }

        swarm = await _call(client, "run_swarm", payload)
        run_id = _extract_run_id(swarm.get("result"))
        return {
            "schema": "cygnus.vibe.asset_research.native.v1",
            "asset": asset,
            "target": meta["target"],
            "preset": meta["preset"],
            "status": "STARTED" if swarm.get("ok") and run_id else "FAILED_TO_START",
            "run_id": run_id,
            "swarm": swarm,
            "mode": "RESEARCH_ONLY",
            "live": False,
            "shell_tools": False,
            "broker_execution": False,
            "started_at_utc": time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()),
        }


async def inspect(action: str, run_id: str, mcp_url: str) -> dict[str, Any]:
    if run_id == "health":
        return await full_health(mcp_url)

    run_id = _safe_run_id(run_id)
    tool = "get_swarm_status" if action == "status" else "get_run_result"
    async with Client(mcp_url) as client:
        await client.ping()
        call = await _call(client, tool, {"run_id": run_id})
    return {
        "schema": "cygnus.vibe.asset_research.native.v1",
        "action": action,
        "run_id": run_id,
        "status": "CHECKED",
        "call": call,
        "mode": "RESEARCH_ONLY",
        "live": False,
        "shell_tools": False,
        "broker_execution": False,
        "checked_at_utc": time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()),
    }


async def run(args: argparse.Namespace) -> int:
    EVIDENCE_ROOT.mkdir(parents=True, exist_ok=True)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())

    if args.action == "start":
        evidence = await start(args.asset, args.mcp_url)
        asset = _normalize_asset(args.asset)
        path = EVIDENCE_ROOT / f"asset-research-native-{asset.lower()}-{stamp}.json"
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
        if evidence.get("status") != "STARTED":
            print("DETAIL=" + json.dumps(evidence, ensure_ascii=False, default=str)[:6000])
            return 2
        return 0

    if not args.run_id:
        raise ValueError("RUN_ID_REQUIRED")
    evidence = await inspect(args.action, args.run_id, args.mcp_url)
    path = EVIDENCE_ROOT / f"asset-research-native-{args.action}-{stamp}.json"
    path.write_text(json.dumps(evidence, indent=2, ensure_ascii=False, default=str), encoding="utf-8")

    print("VIBE_ASSET_RESEARCH_CHECK")
    print(f"ACTION={args.action}")
    print(f"RUN_ID={args.run_id}")
    print(f"RESEARCH_STATUS={evidence.get('status')}")
    print("MODE=RESEARCH_ONLY")
    print("LIVE=false")
    print("SHELL_TOOLS=false")
    print("BROKER_EXECUTION=false")
    print(f"EVIDENCE={path}")
    return 0 if evidence.get("status") != "FAIL" else 2


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
