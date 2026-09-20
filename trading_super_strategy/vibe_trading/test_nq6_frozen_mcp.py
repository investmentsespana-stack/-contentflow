import asyncio
import json
import os
from pathlib import Path

from mcp import ClientSession, StdioServerParameters
from mcp.client.stdio import stdio_client

EXPECTED = [
    "Strategy 2.36.115.sqx",
    "Strategy 2.37.117.sqx",
    "Strategy 2.37.137.sqx",
    "Strategy 2.38.122.sqx",
    "Strategy 2.38.155.sqx",
    "Strategy 2.38.177.sqx",
]
ARCHIVE_SHA256 = "efb90471a5672266ce80d2e947dab704376f60cad27e9ac05540bbc054722991"

def extract_text(result):
    parts = []
    for item in getattr(result, "content", []) or []:
        text = getattr(item, "text", None)
        if text:
            parts.append(text)
    return "\n".join(parts)

async def main():
    manifest = Path("data/nq6_frozen_manifest.json").resolve()
    if not manifest.exists():
        raise SystemExit("manifest_missing")

    local = json.loads(manifest.read_text(encoding="utf-8"))
    if local["source_archive"]["sha256"] != ARCHIVE_SHA256:
        raise SystemExit("archive_sha_mismatch")
    names = [x["name"] for x in local["strategies"]]
    if names != EXPECTED or len(names) != 6:
        raise SystemExit("frozen_identity_mismatch")
    if local["mode"] != "RESEARCH_ONLY" or local["live"] is not False or local["shell_tools"] is not False:
        raise SystemExit("research_only_contract_failed")

    env = dict(os.environ)
    env["VIBE_TRADING_ENABLE_SHELL_TOOLS"] = "0"

    params = StdioServerParameters(
        command="vibe-trading-mcp",
        args=[],
        env=env,
    )

    async with stdio_client(params) as (read, write):
        async with ClientSession(read, write) as session:
            await session.initialize()
            listing = await session.list_tools()
            tool_names = sorted(t.name for t in listing.tools)
            required = {"read_file", "list_skills"}
            missing = sorted(required.difference(tool_names))
            if missing:
                raise SystemExit("missing_vibe_tools:" + ",".join(missing))

            skills = await session.call_tool("list_skills", {})
            if getattr(skills, "isError", False):
                raise SystemExit("list_skills_failed")

            read_result = await session.call_tool("read_file", {"path": str(manifest)})
            if getattr(read_result, "isError", False):
                raise SystemExit("read_file_failed")
            text = extract_text(read_result)
            for name in EXPECTED:
                if name not in text:
                    raise SystemExit("vibe_did_not_ingest:" + name)
            if ARCHIVE_SHA256 not in text:
                raise SystemExit("vibe_archive_identity_missing")

            print("VIBE_NQ6_FROZEN_SMOKE_PASS")
            print("VIBE_VERSION=0.1.15")
            print("MODE=RESEARCH_ONLY")
            print("LIVE=false")
            print("SHELL_TOOLS=false")
            print("STRATEGIES=6")
            print("ARCHIVE_SHA256=" + ARCHIVE_SHA256)
            print("MCP_TOOLS_DISCOVERED=" + str(len(tool_names)))
            print("READ_FILE=PASS")
            print("LIST_SKILLS=PASS")

if __name__ == "__main__":
    asyncio.run(main())
