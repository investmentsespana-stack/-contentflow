"""Patch Vibe 0.1.15 market-data routing for Cygnus futures research.

In CYGNUS_RESEARCH_ONLY mode, Yahoo continuous futures symbols (=F):
- source=auto is promoted to source=yahoo;
- explicit non-Yahoo sources fail closed.

The patch is idempotent and preserves a one-time backup beside the upstream file.
"""
from __future__ import annotations

import importlib.util
import py_compile
from pathlib import Path

spec = importlib.util.find_spec("src.tools.market_data_tool")
if spec is None or not spec.origin:
    raise SystemExit("VIBE_MARKET_DATA_TOOL_NOT_FOUND")

path = Path(spec.origin).resolve()
text = path.read_text(encoding="utf-8")
original = text

if "import os\n" not in text:
    text = text.replace("import json\nimport re\n", "import json\nimport os\nimport re\n", 1)

marker = "CYGNUS_FUTURES_SOURCE_MUST_BE_YAHOO"
if marker not in text:
    old = '''        source = kwargs.get("source", "auto")
        if source not in _SOURCE_ENUM:
            return _error(f"source must be one of {_SOURCE_ENUM}")
'''
    new = old + '''
        # Cygnus research contract: Yahoo continuous futures symbols (=F)
        # always use the direct Yahoo loader. This prevents the generic
        # futures chain (akshare/local) from being selected by source=auto.
        cygnus_research = os.getenv("CYGNUS_RESEARCH_ONLY", "").strip() == "1"
        yahoo_futures = any(code.upper().endswith("=F") for code in codes)
        if cygnus_research and yahoo_futures:
            if source == "auto":
                source = "yahoo"
            elif source != "yahoo":
                return _error("CYGNUS_FUTURES_SOURCE_MUST_BE_YAHOO")
'''
    if old not in text:
        raise SystemExit("VIBE_MARKET_DATA_PATCH_ANCHOR_NOT_FOUND")
    text = text.replace(old, new, 1)

if text != original:
    backup = path.with_suffix(path.suffix + ".before-cygnus-futures-route.bak")
    if not backup.exists():
        backup.write_text(original, encoding="utf-8")
    path.write_text(text, encoding="utf-8")

py_compile.compile(str(path), doraise=True)
print(f"CYGNUS_FUTURES_DATA_ROUTE_FIX=PASS path={path}")
