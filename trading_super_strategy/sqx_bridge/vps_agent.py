from __future__ import annotations

import argparse
import asyncio
import json
import os
import socket
import stat
import sys
import time
from pathlib import Path
from typing import Any

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

CONTROL_URL = os.getenv(
    "CYGNUS_SQX_CONTROL_URL",
    "https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/sqx-bridge",
)
DEFAULT_MCP_URL = os.getenv("CYGNUS_SQX_MCP_URL", "http://127.0.0.1:8080/mcp")
CONFIG_DIR = Path(os.getenv("CYGNUS_SQX_CONFIG_DIR", "/etc/cygnus-sqx-vps-bridge"))
CONFIG_PATH = CONFIG_DIR / "config.json"
TOKEN_PATH = CONFIG_DIR / "bridge.token"

# The VPS bridge never exposes an inbound TCP listener. It only makes outbound HTTPS
# calls to the existing Supabase control plane and localhost calls to StrategyQuant MCP.
LOCAL_ALLOWLIST = {
    "list_projects",
    "list_strategies",
    "list_databanks",
    "get_strategy_stats",
    "run_project",
    "stop_project",
}
READ_ONLY = {
    "list_projects",
    "list_strategies",
    "list_databanks",
    "get_strategy_stats",
}


def _ensure_config_dir() -> None:
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)


def _write_private(path: Path, value: str) -> None:
    _ensure_config_dir()
    path.write_text(value, encoding="utf-8")
    try:
        path.chmod(stat.S_IRUSR | stat.S_IWUSR)
    except PermissionError:
        pass


def load_config() -> dict[str, Any]:
    if not CONFIG_PATH.exists():
        return {}
    return json.loads(CONFIG_PATH.read_text(encoding="utf-8"))


def save_config(cfg: dict[str, Any]) -> None:
    _ensure_config_dir()
    CONFIG_PATH.write_text(json.dumps(cfg, indent=2), encoding="utf-8")


def load_token() -> str:
    if not TOKEN_PATH.exists():
        return ""
    return TOKEN_PATH.read_text(encoding="utf-8").strip()


class ControlPlane:
    def __init__(self, token: str = "") -> None:
        self.token = token

    def post(self, body: dict[str, Any]) -> dict[str, Any]:
        headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
        with httpx.Client(timeout=20.0) as client:
            response = client.post(CONTROL_URL, json=body, headers=headers)
            response.raise_for_status()
            return response.json()

    @staticmethod
    def pair(code: str, device_name: str) -> dict[str, Any]:
        with httpx.Client(timeout=20.0) as client:
            response = client.post(
                CONTROL_URL,
                json={"action": "pair", "code": code, "device_name": device_name},
            )
            response.raise_for_status()
            return response.json()


async def sqx_tools(url: str) -> list[str]:
    async with streamablehttp_client(url) as transport:
        read, write = transport[0], transport[1]
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.list_tools()
            return sorted({str(t.name) for t in result.tools})


async def sqx_call(url: str, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    if name not in LOCAL_ALLOWLIST:
        raise RuntimeError(f"blocked_by_local_allowlist:{name}")
    async with streamablehttp_client(url) as transport:
        read, write = transport[0], transport[1]
        async with ClientSession(read, write) as session:
            await session.initialize()
            available = {str(t.name) for t in (await session.list_tools()).tools}
            if name not in available:
                raise RuntimeError(f"sqx_tool_unavailable:{name}")
            result = await session.call_tool(name, arguments=arguments or {})
            if hasattr(result, "model_dump"):
                return result.model_dump(mode="json")
            return {"value": str(result)}


def pair(code: str, device_name: str, mcp_url: str) -> None:
    payload = ControlPlane.pair(code, device_name)
    if not payload.get("ok"):
        raise RuntimeError(payload.get("error", "pair_failed"))
    cfg = {
        "device_id": str(payload["device_id"]),
        "device_name": str(payload.get("device_name") or device_name),
        "mcp_url": mcp_url,
        "paired_at_unix": int(time.time()),
    }
    save_config(cfg)
    _write_private(TOKEN_PATH, str(payload["bridge_token"]))
    print(json.dumps({"ok": True, "device_id": cfg["device_id"], "device_name": cfg["device_name"]}))


def heartbeat(control: ControlPlane, mcp_url: str, allow_project_control: bool) -> dict[str, Any]:
    try:
        available = asyncio.run(sqx_tools(mcp_url))
        effective = sorted(LOCAL_ALLOWLIST.intersection(available))
        if not allow_project_control:
            effective = sorted(READ_ONLY.intersection(effective))
        health = {
            "hostname": socket.gethostname(),
            "platform": sys.platform,
            "bridge_kind": "headless_vps",
            "mcp_url": mcp_url,
            "sqx_connected": True,
            "sqx_tools": available,
            "capabilities": effective,
            "project_control_enabled": allow_project_control,
            "no_inbound_listener": True,
            "no_arbitrary_shell": True,
            "live_trading": False,
        }
    except Exception as exc:
        health = {
            "hostname": socket.gethostname(),
            "platform": sys.platform,
            "bridge_kind": "headless_vps",
            "mcp_url": mcp_url,
            "sqx_connected": False,
            "sqx_error": str(exc)[:1000],
            "capabilities": [],
            "project_control_enabled": allow_project_control,
            "no_inbound_listener": True,
            "no_arbitrary_shell": True,
            "live_trading": False,
        }
    return control.post({"action": "heartbeat", "health": health})


def daemon(poll_seconds: float, heartbeat_seconds: float) -> None:
    cfg = load_config()
    token = load_token()
    if not cfg or not token:
        raise SystemExit(
            "Bridge is not paired. Provision it with --pair using a one-use code."
        )

    mcp_url = str(cfg.get("mcp_url") or DEFAULT_MCP_URL)
    allow_project_control = os.getenv("CYGNUS_ALLOW_PROJECT_CONTROL", "0").lower() in {
        "1",
        "true",
        "yes",
    }
    control = ControlPlane(token)
    last_hb = 0.0

    while True:
        try:
            now = time.time()
            if now - last_hb >= heartbeat_seconds:
                heartbeat(control, mcp_url, allow_project_control)
                last_hb = now

            claimed = control.post({"action": "claim"})
            command = claimed.get("command")
            if not command:
                time.sleep(poll_seconds)
                continue

            cid = str(command.get("id") or "")
            nonce = str(command.get("claim_nonce") or "")
            ctype = str(command.get("command_type") or "")
            payload = command.get("payload") or {}

            try:
                if ctype not in LOCAL_ALLOWLIST:
                    raise RuntimeError(f"blocked_by_local_allowlist:{ctype}")
                if ctype not in READ_ONLY and not allow_project_control:
                    raise RuntimeError("project_control_disabled_on_vps")
                result = asyncio.run(sqx_call(mcp_url, ctype, payload))
                control.post(
                    {
                        "action": "complete",
                        "command_id": cid,
                        "claim_nonce": nonce,
                        "success": True,
                        "result": result,
                    }
                )
            except Exception as exc:
                control.post(
                    {
                        "action": "complete",
                        "command_id": cid,
                        "claim_nonce": nonce,
                        "success": False,
                        "error": str(exc)[:4000],
                    }
                )
        except KeyboardInterrupt:
            raise
        except Exception as exc:
            print(f"bridge_error={exc}", flush=True)
            time.sleep(max(5.0, poll_seconds))


def main() -> None:
    parser = argparse.ArgumentParser(description="Cygnus headless StrategyQuant VPS bridge")
    parser.add_argument("--pair", default="", help="one-use pairing code")
    parser.add_argument("--device-name", default=socket.gethostname())
    parser.add_argument("--mcp-url", default=DEFAULT_MCP_URL)
    parser.add_argument("--poll-seconds", type=float, default=3.0)
    parser.add_argument("--heartbeat-seconds", type=float, default=30.0)
    parser.add_argument("--health-once", action="store_true")
    args = parser.parse_args()

    if args.pair:
        pair(args.pair.strip(), args.device_name.strip() or socket.gethostname(), args.mcp_url)
        return

    if args.health_once:
        cfg = load_config()
        token = load_token()
        if not cfg or not token:
            raise SystemExit("not_paired")
        control = ControlPlane(token)
        print(
            json.dumps(
                heartbeat(
                    control,
                    str(cfg.get("mcp_url") or args.mcp_url),
                    os.getenv("CYGNUS_ALLOW_PROJECT_CONTROL", "0").lower()
                    in {"1", "true", "yes"},
                ),
                indent=2,
            )
        )
        return

    daemon(args.poll_seconds, args.heartbeat_seconds)


if __name__ == "__main__":
    main()
