from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import os
import py_compile
from pathlib import Path

FUTURES_PATTERN_LINE = '    re.compile(r"\\b[A-Z]{1,6}=F\\b"),'
ANCHOR_LINE = '    re.compile(r"\\b[A-Z]{1,5}\\.US\\b"),'


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def locate_grounding() -> tuple[object, Path]:
    import src.swarm.grounding as grounding
    return grounding, Path(grounding.__file__).resolve()


def smoke(grounding: object) -> dict[str, object]:
    expected = {
        "ES": ["ES=F"],
        "NQ": ["NQ=F"],
        "GC": ["GC=F"],
        "CL": ["CL=F"],
    }
    observed = {
        root: grounding.extract_symbols_from_user_vars({"target": f"{root}=F"})
        for root in expected
    }
    mixed = grounding.extract_symbols_from_user_vars(
        {"target": "ES=F", "market": "E-mini S&P 500 futures, CME"}
    )
    ok = observed == expected and mixed and mixed[0] == "ES=F" and "ES.US" not in mixed
    if not ok:
        raise RuntimeError(
            "FUTURES_GROUNDING_SMOKE_FAILED:"
            + json.dumps({"expected": expected, "observed": observed, "mixed": mixed})
        )
    return {"symbols": observed, "mixed_es": mixed, "status": "PASS"}


def apply() -> dict[str, object]:
    grounding, path = locate_grounding()
    original = path.read_text(encoding="utf-8")
    before = sha256_text(original)

    if FUTURES_PATTERN_LINE in original:
        reloaded = importlib.reload(grounding)
        return {
            "status": "ALREADY_FIXED",
            "grounding_path": str(path),
            "sha256": before,
            "smoke": smoke(reloaded),
        }

    if original.count(ANCHOR_LINE) != 1:
        raise RuntimeError(
            "FUTURES_GROUNDING_PRECONDITION_FAILED:"
            + json.dumps({"anchor_count": original.count(ANCHOR_LINE)})
        )

    patched = original.replace(
        ANCHOR_LINE,
        FUTURES_PATTERN_LINE + "\n" + ANCHOR_LINE,
        1,
    )
    compile(patched, str(path), "exec")

    backup = path.with_name(path.name + ".pre-futures-eqf.bak")
    if not backup.exists():
        backup.write_text(original, encoding="utf-8")

    temp_path = path.with_name(path.name + ".cygnus-new")
    temp_path.write_text(patched, encoding="utf-8")
    os.replace(temp_path, path)
    py_compile.compile(str(path), doraise=True)

    reloaded = importlib.reload(grounding)
    return {
        "status": "PATCHED",
        "grounding_path": str(path),
        "backup_path": str(backup),
        "sha256_before": before,
        "sha256_after": sha256_text(path.read_text(encoding="utf-8")),
        "smoke": smoke(reloaded),
    }


def check() -> dict[str, object]:
    grounding, path = locate_grounding()
    text = path.read_text(encoding="utf-8")
    present = FUTURES_PATTERN_LINE in text
    result = {
        "status": "PASS" if present else "FAIL",
        "grounding_path": str(path),
        "sha256": sha256_text(text),
        "futures_pattern_present": present,
    }
    if present:
        result["smoke"] = smoke(grounding)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = check() if args.check else apply()
    print("VIBE_FUTURES_GROUNDING_FIX=" + str(result["status"]))
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result["status"] in {"PASS", "PATCHED", "ALREADY_FIXED"} else 2


if __name__ == "__main__":
    raise SystemExit(main())
