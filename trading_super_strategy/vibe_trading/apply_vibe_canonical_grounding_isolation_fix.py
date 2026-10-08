"""Disable Vibe network grounding for Cygnus canonical-data research runs."""
from __future__ import annotations

import importlib.util
import py_compile
from pathlib import Path

spec = importlib.util.find_spec("src.swarm.grounding")
if spec is None or not spec.origin:
    raise SystemExit("VIBE_SWARM_GROUNDING_NOT_FOUND")

path = Path(spec.origin).resolve()
text = path.read_text(encoding="utf-8")
original = text
marker = 'and isinstance(user_vars.get("data_contract"), str)'

if marker not in text:
    old = '''def extract_symbols_from_user_vars(user_vars: dict[str, str]) -> list[str]:
    """Return the deduplicated list of symbols mentioned anywhere in *user_vars*.

    Explicit suffixed symbols come first (in first-occurrence order),
    followed by guarded bare-ticker promotions (``NVDA`` → ``NVDA.US``),
    so explicit symbols always win the grounding cap. See the module
    docstring for the promotion guards.
    """
    explicit: dict[str, None] = {}  # ordered set
'''
    new = '''def extract_symbols_from_user_vars(user_vars: dict[str, str]) -> list[str]:
    """Return the deduplicated list of symbols mentioned anywhere in *user_vars*.

    Cygnus research runs that carry a canonical data_contract intentionally
    disable Vibe\'s automatic network grounding. Those runs use immutable local
    datasets with per-timeframe aliases/checksums, so scanning policy prose for
    bare US tickers can only add unrelated evidence (for example MUST.US).
    """
    if (
        os.getenv("CYGNUS_RESEARCH_ONLY", "").strip() == "1"
        and isinstance(user_vars.get("data_contract"), str)
        and user_vars.get("data_contract", "").strip()
    ):
        return []

    explicit: dict[str, None] = {}  # ordered set
'''
    if old not in text:
        raise SystemExit("VIBE_CANONICAL_GROUNDING_ANCHOR_NOT_FOUND")
    text = text.replace(old, new, 1)

if text != original:
    backup = path.with_suffix(path.suffix + ".before-cygnus-canonical-grounding.bak")
    if not backup.exists():
        backup.write_text(original, encoding="utf-8")
    path.write_text(text, encoding="utf-8")

py_compile.compile(str(path), doraise=True)
current = path.read_text(encoding="utf-8")
if marker not in current:
    raise SystemExit("VIBE_CANONICAL_GROUNDING_VERIFY_FAILED")
print(f"CYGNUS_CANONICAL_GROUNDING_FIX=PASS path={path}")
