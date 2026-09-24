"""Private stdio bridge to upstream Vibe-Trading; research only.

No public port, broker credentials, inherited secrets, or shell tools.
This connectivity probe does not certify strategy quality or Director runtime.
"""
from __future__ import annotations

import argparse
import asyncio
import json
from pathlib import Path

UPSTREAM_COMMIT = "269d8ce3d1b9ba80c4306585b813cb58520dca9a"
ALLOWED_TOOLS = frozenset({"list_skills"})


async def probe(python: str, server: str, runtime_root: str) -> dict:
    from mcp import ClientSession, StdioServerParameters
    from mcp.client.stdio import stdio_client

    root = Path(runtime_root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    # Do not forward the Director environment or broker/model credentials.
    env = {
        "PATH": str(Path(python).resolve().parent) + ":/usr/bin:/bin",
        "VIBE_TRADING_HOME": str(root),
        "VIBE_TRADING_ENABLE_SHELL_TOOLS": "0",
        "LANGSMITH_TRACING": "false",
        "DO_NOT_TRACK": "1",
    }
    params = StdioServerParameters(command=python, args=[server], env=env, cwd=str(root))
    async with asyncio.timeout(60):
        async with stdio_client(params) as (read, write):
            async with ClientSession(read, write) as session:
                await session.initialize()
                listing = await session.list_tools()
                names = {tool.name for tool in listing.tools}
                if names.intersection({"bash", "background_run", "cancel_background"}):
                    raise PermissionError("UNSAFE_SHELL_SURFACE")
                if not ALLOWED_TOOLS.issubset(names):
                    raise RuntimeError("REQUIRED_RESEARCH_TOOL_MISSING")
                response = await session.call_tool("list_skills", {})
                if response.isError:
                    raise RuntimeError("RESEARCH_TOOL_FAILED")
                # Never print raw upstream payloads, tokens, or model configuration.
                return {
                    "status": "MCP_CONNECTIVITY_PASS",
                    "tools_discovered": len(names),
                    "research_call": "list_skills",
                    "shell_tools": False,
                    "live_execution": False,
                    "market_policy": "market_open_no_0900_1200_restriction",
                    "director_runtime_verified": False,
                }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--python", required=True)
    parser.add_argument("--server", required=True)
    parser.add_argument("--runtime-root", required=True)
    args = parser.parse_args()
    print(json.dumps(asyncio.run(probe(args.python, args.server, args.runtime_root))))


if __name__ == "__main__":
    main()
