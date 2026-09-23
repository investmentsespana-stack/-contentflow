[Reading 976 lines from start (total: 976 lines, 0 remaining)]

from __future__ import annotations

import argparse
import asyncio
import importlib.metadata
import json
import os
import re
import sys
import time
from pathlib import Path
from typing import Any

from fastmcp import Client

MODULE_DIR = Path(__file__).resolve().parent
if str(MODULE_DIR) not in sys.path:
    sys.path.insert(0, str(MODULE_DIR))

from tradingview_futures_guard import (
    build_snapshot_plan,
    codex_policy_text,
    resolve_route,
    validate_timeframes,
)
from canonical_market_data import (
    compact_contract,
    ensure_contract,
    verify_contract,
)

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
os.environ["LANGCHAIN_MODEL_NAME"] = "openai-codex/gpt-5.6-terra"
os.environ["VIBE_TRADING_ENABLE_SHELL_TOOLS"] = "0"
os.environ["CYGNUS_RESEARCH_ONLY"] = "1"
os.environ["VIBE_TRADING_DATA_CACHE"] = "1"
os.environ["VIBE_TRADING_DATA_CACHE_ROOT"] = str(ROOT / "data" / "loader-cache")

# Yahoo-style continuous futures (=F) are served correctly by Vibe's Yahoo loader,
# but Vibe 0.1.15's generic futures auto chain does not include Yahoo for backtests.
# Pin the backtest source explicitly and fail closed if a live data probe cannot serve it.
FUTURES_BACKTEST_SOURCE = "yahoo"

ASSETS: dict[str, dict[str, str]] = {
    "CL": {
        "target": "CL=F",
        "market": "WTI crude oil futures, NYMEX/CME",
        "preset": "cygnus_futures_strategy_lab",
        "goal": "discover diverse systematic CL strategies with real-data backtests, OOS validation and robustness evidence",
        "tv_symbol": "NYMEX:CL1!",
        "tv_category": "energy",
    },
    "ES": {
        "target": "ES=F",
        "market": "E-mini S&P 500 futures, CME",
        "preset": "cygnus_futures_strategy_lab",
        "goal": "discover diverse systematic ES strategies with real-data backtests, OOS validation and robustness evidence",
        "tv_symbol": "CME:ES1!",
        "tv_category": "equity_index",
    },
    "NQ": {
        "target": "NQ=F",
        "market": "E-mini Nasdaq-100 futures, CME",
        "preset": "cygnus_futures_strategy_lab",
        "goal": "discover diverse systematic NQ strategies with real-data backtests, OOS validation and robustness evidence",
        "tv_symbol": "CME:NQ1!",
        "tv_category": "equity_index",
    },
    "GC": {
        "target": "GC=F",
        "market": "Gold futures, COMEX",
        "preset": "cygnus_futures_strategy_lab",
        "goal": "discover diverse systematic GC strategies with real-data backtests, OOS validation and robustness evidence",
        "tv_symbol": "COMEX:GC1!",
        "tv_category": "metals",
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


def _swarm_run_dir_contract() -> dict[str, Any]:
    """Verify the installed Vibe swarm worker contains the upstream run_dir fix."""
    import tempfile
    from types import SimpleNamespace
    import src.swarm.worker as worker

    path = Path(worker.__file__).resolve()
    text = path.read_text(encoding="utf-8")
    vulnerable = 'args = {**tc.arguments, "run_dir": str(artifact_dir)}' in text
    helper_present = "def _tool_arguments(" in text
    fixed_dispatch = "args, run_dir_refusal = _tool_arguments(" in text
    refusal_dispatch = "if run_dir_refusal is not None:" in text

    probe_ok = False
    escape_guard_ok = False
    if helper_present:
        workspace = Path(tempfile.mkdtemp(prefix="vibe-run-dir-contract-")) / "artifacts" / "backtester"
        workspace.mkdir(parents=True, exist_ok=True)
        declared = SimpleNamespace(parameters={"properties": {"run_dir": {"type": "string"}}})
        args, refusal = worker._tool_arguments(declared, {"run_dir": "runs/probe"}, workspace)
        probe_ok = (
            refusal is None
            and Path(args.get("run_dir", "")).resolve()
            == (workspace.resolve() / "runs" / "probe").resolve()
        )
        _, escape_refusal = worker._tool_arguments(
            declared, {"run_dir": "../../escape"}, workspace
        )
        escape_guard_ok = bool(escape_refusal)

    return {
        "ok": (
            not vulnerable
            and helper_present
            and fixed_dispatch
            and refusal_dispatch
            and probe_ok
            and escape_guard_ok
        ),
        "worker_path": str(path),
        "upstream_fix_commit": "e30a6427ee79cae5cd06d7444671df23ddbba4fc",
        "vulnerable_overwrite_present": vulnerable,
        "helper_present": helper_present,
        "fixed_dispatch": fixed_dispatch,
        "refusal_dispatch": refusal_dispatch,
        "relative_run_dir_probe": probe_ok,
        "escape_guard_probe": escape_guard_ok,
    }


def _futures_preset_contract() -> dict[str, Any]:
    """Ensure runtime variables live in task templates, where Vibe renders them."""
    import yaml

    candidates = [
        Path.home() / ".vibe-trading" / "swarm" / "presets" / "cygnus_futures_strategy_lab.yaml",
        STATE_ROOT / "swarm" / "presets" / "cygnus_futures_strategy_lab.yaml",
    ]
    path = next((p for p in candidates if p.is_file()), None)
    if path is None:
        return {"ok": False, "reason": "preset_not_found", "paths": [str(p) for p in candidates]}

    data = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
    placeholders = (
        "{target}", "{market}", "{goal}", "{tv_symbol}",
        "{tv_category}", "{tv_policy}", "{research_timeframes}", "{backtest_source}", "{data_contract}",
    )
    bad_system_prompts: dict[str, list[str]] = {}
    for agent in data.get("agents", []) or []:
        prompt = str(agent.get("system_prompt") or "")
        bad = [token for token in placeholders if token in prompt]
        if bad:
            bad_system_prompts[str(agent.get("id") or "unknown")] = bad

    task_prompts = {
        str(task.get("id") or ""): str(task.get("prompt_template") or "")
        for task in (data.get("tasks", []) or [])
    }
    required_task_ids = {
        "task-regime", "task-architecture", "task-backtests",
        "task-robustness", "task-judge",
    }
    missing_tasks = sorted(required_task_ids - set(task_prompts))
    missing_routing_vars = {
        task_id: [
            token for token in (
                "{target}", "{tv_symbol}", "{tv_category}",
                "{tv_policy}", "{research_timeframes}", "{data_contract}",
            )
            if token not in task_prompts.get(task_id, "")
        ]
        for task_id in sorted(required_task_ids)
    }
    missing_routing_vars = {
        key: value for key, value in missing_routing_vars.items() if value
    }
    backtest_prompt = task_prompts.get("task-backtests", "")
    relative_run_dir_contract = (
        'runs/<candidate_id>' in backtest_prompt
        and 'run_dir="runs/<candidate_id>"' in backtest_prompt
    )
    backtest_source_contract = (
        "{backtest_source}" in backtest_prompt
        and '"source": "{backtest_source}"' in backtest_prompt
    )

    return {
        "ok": (
            not bad_system_prompts
            and not missing_tasks
            and not missing_routing_vars
            and relative_run_dir_contract
            and backtest_source_contract
        ),
        "preset_path": str(path),
        "system_prompt_placeholders": bad_system_prompts,
        "missing_tasks": missing_tasks,
        "missing_routing_vars": missing_routing_vars,
        "relative_run_dir_contract": relative_run_dir_contract,
        "backtest_source_contract": backtest_source_contract,
    }



def _futures_grounding_contract() -> dict[str, Any]:
    """Verify futures symbols survive swarm grounding without .US promotion."""
    import src.swarm.grounding as grounding

    observed = {
        root: grounding.extract_symbols_from_user_vars({"target": f"{root}=F"})
        for root in ("ES", "NQ", "GC", "CL")
    }
    expected = {root: [f"{root}=F"] for root in ("ES", "NQ", "GC", "CL")}
    mixed = grounding.extract_symbols_from_user_vars(
        {"target": "ES=F", "market": "E-mini S&P 500 futures, CME"}
    )
    ok = observed == expected and mixed and mixed[0] == "ES=F" and "ES.US" not in mixed
    return {
        "ok": bool(ok),
        "expected": expected,
        "observed": observed,
        "mixed_es": mixed,
        "grounding_path": str(Path(grounding.__file__).resolve()),
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



def _swarm_run_dir_fix_status() -> dict[str, Any]:
    """Fail closed if Vibe 0.1.15 regresses the official swarm run_dir fix.

    Official upstream fix:
    HKUDS/Vibe-Trading commit e30a6427ee79cae5cd06d7444671df23ddbba4fc
    (2026-09-13).  The vulnerable worker overwrote every tool-declared
    run_dir with the agent workspace root, causing valid candidate
    config.json files to be invisible to the backtest tool.
    """
    import src.swarm.worker as swarm_worker

    worker_path = Path(swarm_worker.__file__).resolve()
    text = worker_path.read_text(encoding="utf-8")
    vulnerable = 'args = {**tc.arguments, "run_dir": str(artifact_dir)}'
    fixed_dispatch = "args, run_dir_refusal = _tool_arguments("

    return {
        "ok": (
            "def _tool_arguments(" in text
            and fixed_dispatch in text
            and vulnerable not in text
        ),
        "upstream_commit": "e30a6427ee79cae5cd06d7444671df23ddbba4fc",
        "worker_path": str(worker_path),
        "has_tool_arguments": "def _tool_arguments(" in text,
        "has_fixed_dispatch": fixed_dispatch in text,
        "has_vulnerable_overwrite": vulnerable in text,
    }



def _futures_grounding_status() -> dict[str, Any]:
    """Verify swarm grounding preserves Yahoo continuous-futures symbols."""
    from src.swarm.grounding import extract_symbols_from_user_vars

    probes = {
        "ES": extract_symbols_from_user_vars({"target": "ES=F"}),
        "NQ": extract_symbols_from_user_vars({"target": "NQ=F"}),
        "GC": extract_symbols_from_user_vars({"target": "GC=F"}),
        "CL": extract_symbols_from_user_vars({"target": "CL=F"}),
    }
    expected = {root: [f"{root}=F"] for root in probes}
    return {
        "ok": probes == expected,
        "probes": probes,
        "expected": expected,
        "invariant": "Yahoo continuous futures must not be promoted to .US equities",
    }


def _futures_backtest_source_contract(asset: str = "ES") -> dict[str, Any]:
    """Verify the frozen Cygnus Yahoo dataset through Vibe's real backtest loader."""
    from backtest.runner import fetch_data_map

    asset = _normalize_asset(asset)
    if asset == "DXY":
        return {"ok": True, "asset": asset, "reason": "not_futures_contract"}

    contract_state = ensure_contract(asset)
    if not contract_state.get("ok"):
        return {
            "ok": False,
            "asset": asset,
            "reason": "canonical_contract_unavailable",
            "contract": contract_state,
        }

    manifest = contract_state["manifest"]
    symbol = manifest["symbol"]
    probes: dict[str, Any] = {}
    for interval, meta in manifest["timeframes"].items():
        try:
            fetched = fetch_data_map({
                "codes": [symbol],
                "source": FUTURES_BACKTEST_SOURCE,
                "start_date": meta["start_date"],
                "end_date": meta["end_date"],
                "interval": interval,
            })
            frame = fetched.data_map.get(symbol)
            rows = int(len(frame)) if frame is not None else 0
            effective = [str(x) for x in fetched.effective_sources]
            expected_rows = int(meta["rows"])
            probes[interval] = {
                "ok": (
                    rows == expected_rows
                    and FUTURES_BACKTEST_SOURCE in effective
                ),
                "rows": rows,
                "expected_rows": expected_rows,
                "effective_sources": effective,
                "start_date": meta["start_date"],
                "end_date": meta["end_date"],
                "sha256": meta["sha256"],
            }
        except Exception as exc:
            probes[interval] = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

    return {
        "ok": all(bool(v.get("ok")) for v in probes.values()),
        "asset": asset,
        "source": FUTURES_BACKTEST_SOURCE,
        "symbol": symbol,
        "settled_end": manifest["settled_end"],
        "probes": probes,
        "invariant": (
            "Every swarm worker and backtest must use the exact frozen Yahoo "
            "window/checksum contract; no fresh per-agent market-data window."
        ),
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
    if isinstance(rows, list):
        return len(rows)
    if isinstance(rows, dict):
        points = rows.get("data")
        if isinstance(points, list):
            return len(points)
        for key in ("returned", "rows"):
            try:
                value = int(rows.get(key) or 0)
            except (TypeError, ValueError):
                value = 0
            if value > 0:
                return value
    return 0


def _source_for_symbol(payload: Any, symbol: str) -> str | None:
    data = _json_layers(payload)
    if not isinstance(data, dict):
        return None
    provenance = data.get("_provenance")
    if not isinstance(provenance, dict):
        return None
    item = provenance.get(symbol)
    if not isinstance(item, dict):
        return None
    source = item.get("source")
    return str(source).strip().lower() if source else None


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
        evidence["checks"]["swarm_run_dir_fix"] = _swarm_run_dir_fix_status()
    except Exception as exc:
        evidence["checks"]["swarm_run_dir_fix"] = {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
            "upstream_commit": "e30a6427ee79cae5cd06d7444671df23ddbba4fc",
        }

    try:
        evidence["checks"]["futures_backtest_source"] = _futures_backtest_source_contract()
    except Exception as exc:
        evidence["checks"]["futures_backtest_source"] = {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
            "source": FUTURES_BACKTEST_SOURCE,
        }

    try:
        canonical = {asset: verify_contract(asset) for asset in ("ES", "NQ", "GC", "CL")}
        evidence["checks"]["canonical_market_data"] = {
            "ok": all(bool(item.get("ok")) for item in canonical.values()),
            "assets": canonical,
        }
    except Exception as exc:
        evidence["checks"]["canonical_market_data"] = {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
        }

    try:
        evidence["checks"]["futures_grounding"] = _futures_grounding_status()
    except Exception as exc:
        evidence["checks"]["futures_grounding"] = {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
        }

    try:
        provider = _provider_snapshot()
        evidence["checks"]["provider"] = {
            "ok": (
                provider.get("provider", "").lower().replace("_", "-") == "openai-codex"
                and provider.get("model") == "openai-codex/gpt-5.6-terra"
                and provider.get("oauth_ready") is True
            ),
            **provider,
        }
    except Exception as exc:
        evidence["checks"]["provider"] = {"ok": False, "error": f"{type(exc).__name__}: {exc}"}

    try:
        evidence["checks"]["swarm_run_dir_contract"] = _swarm_run_dir_contract()
    except Exception as exc:
        evidence["checks"]["swarm_run_dir_contract"] = {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
        }

    try:
        evidence["checks"]["futures_preset_contract"] = _futures_preset_contract()
    except Exception as exc:
        evidence["checks"]["futures_preset_contract"] = {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
        }

    try:
        evidence["checks"]["futures_grounding_contract"] = _futures_grounding_contract()
    except Exception as exc:
        evidence["checks"]["futures_grounding_contract"] = {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
        }

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
        plan = build_snapshot_plan()
        validate_timeframes(("5m", "15m", "1h", "4h"))
        route_consistency = all(
            ASSETS[root].get("tv_symbol") == resolve_route(root).qualified_symbol
            and ASSETS[root].get("tv_category") == resolve_route(root).category
            for root in ("NQ", "ES", "GC", "CL")
        )
        evidence["checks"]["tradingview_futures_guard"] = {
            "ok": route_consistency,
            "plan": plan,
            "policy": codex_policy_text(),
        }
    except Exception as exc:
        evidence["checks"]["tradingview_futures_guard"] = {
            "ok": False,
            "error": f"{type(exc).__name__}: {exc}",
        }

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
            blocked_non_yahoo = await _call(
                client,
                "get_market_data",
                {
                    "codes": ["ES=F"],
                    "start_date": "2026-09-15",
                    "end_date": "2026-09-20",
                    "source": "akshare",
                    "interval": "1H",
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
            futures_sources = {
                symbol: _source_for_symbol(futures_data.get("result"), symbol)
                for symbol in ("CL=F", "ES=F", "NQ=F", "GC=F")
            }
            rows["DX-Y.NYB"] = _rows_for_symbol(dxy_data.get("result"), "DX-Y.NYB")
            blocked_blob = json.dumps(blocked_non_yahoo, ensure_ascii=False, default=str)
            evidence["checks"]["market_data"] = {
                "ok": (
                    all(v > 0 for v in rows.values())
                    and all(v == "yahoo" for v in futures_sources.values())
                    and "CYGNUS_FUTURES_SOURCE_MUST_BE_YAHOO" in blocked_blob
                ),
                "rows": rows,
                "futures_sources": futures_sources,
                "non_yahoo_blocked": "CYGNUS_FUTURES_SOURCE_MUST_BE_YAHOO" in blocked_blob,
                "futures_call": futures_data,
                "blocked_non_yahoo_call": blocked_non_yahoo,
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

    if asset != "DXY":
        futures_data_gate = _futures_backtest_source_contract(asset)
        if not futures_data_gate.get("ok"):
            return {
                "schema": "cygnus.vibe.asset_research.native.v1",
                "asset": asset,
                "status": "BLOCKED_FUTURES_BACKTEST_SOURCE",
                "data_gate": futures_data_gate,
                "mode": "RESEARCH_ONLY",
                "live": False,
                "shell_tools": False,
                "broker_execution": False,
            }

    provider = _provider_snapshot()
    if not (
        provider.get("provider", "").lower().replace("_", "-") == "openai-codex"
        and provider.get("model") == "openai-codex/gpt-5.6-terra"
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
                    "tv_symbol": meta["tv_symbol"],
                    "tv_category": meta["tv_category"],
                    "tv_policy": codex_policy_text(),
                    "research_timeframes": ",".join(validate_timeframes(("5m", "15m", "1h", "4h"))),
                    "backtest_source": FUTURES_BACKTEST_SOURCE,
                    "data_contract": compact_contract(asset),
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

[executed on device: WIN-31RCI8K7JR2 (dfb74cc6-deae-45bc-8c9d-634f7d1202b2)]