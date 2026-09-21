from __future__ import annotations

import argparse
import asyncio
import json
import os
from pathlib import Path

ROOT = Path(r"C:\Cygnus\VibeTrading")
STATE = ROOT / "state"
os.environ["VIBE_TRADING_HOME"] = str(STATE)
os.environ["VIBE_TRADING_ENABLE_SHELL_TOOLS"] = "0"
os.environ["CYGNUS_RESEARCH_ONLY"] = "1"

import asset_research  # noqa: E402


async def main_async(mcp_url: str) -> int:
    evidence = await asset_research.full_health(mcp_url)
    path = ROOT / "evidence" / "vibe-full-health-latest.json"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(evidence, indent=2, ensure_ascii=False, default=str), encoding="utf-8")
    print("VIBE_FULL_HEALTH=" + str(evidence.get("status")))
    print("PROVIDER=" + str(evidence.get("checks", {}).get("provider", {}).get("provider")))
    print("MODEL=" + str(evidence.get("checks", {}).get("provider", {}).get("model")))
    print("OAUTH_READY=" + str(evidence.get("checks", {}).get("provider", {}).get("oauth_ready")).lower())
    print("MCP_TOOLS=" + str(evidence.get("checks", {}).get("mcp", {}).get("tool_count", 0)))
    print("SKILLS=" + str(evidence.get("checks", {}).get("inventory", {}).get("skill_count", 0)))
    print("MODE=RESEARCH_ONLY")
    print("LIVE=false")
    print("SHELL_TOOLS=false")
    print("BROKER_EXECUTION=false")
    print("EVIDENCE=" + str(path))
    if evidence.get("status") != "PASS":
        print("DETAIL=" + json.dumps(evidence, ensure_ascii=False, default=str)[:10000])
        return 2
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mcp-url", default="http://127.0.0.1:8900/mcp")
    args = parser.parse_args()
    return asyncio.run(main_async(args.mcp_url))


if __name__ == "__main__":
    raise SystemExit(main())
