from __future__ import annotations

import argparse
import hashlib
import importlib
import json
import os
import py_compile
import tempfile
from pathlib import Path
from types import SimpleNamespace

UPSTREAM_COMMIT = "e30a6427ee79cae5cd06d7444671df23ddbba4fc"
VULNERABLE_DISPATCH = '            args = {**tc.arguments, "run_dir": str(artifact_dir)}'
FIXED_DISPATCH = '''            args, run_dir_refusal = _tool_arguments(
                registry.get(tc.name), tc.arguments, artifact_dir
            )'''
OLD_EXEC = "                result = registry.execute(tc.name, args)"
NEW_EXEC = '''                if run_dir_refusal is not None:
                    result = json.dumps(
                        {"status": "error", "error": run_dir_refusal},
                        ensure_ascii=False,
                    )
                else:
                    result = registry.execute(tc.name, args)'''

HELPER = r'''
def _tool_arguments(
    tool: BaseTool | None, arguments: dict[str, Any], artifact_dir: Path
) -> tuple[dict[str, Any], str | None]:
    """Confine a worker tool call run_dir to the agent workspace."""
    args = dict(arguments)
    declared = (getattr(tool, "parameters", None) or {}).get("properties") or {}
    workspace = artifact_dir.resolve()

    if "run_dir" not in declared:
        args["run_dir"] = str(artifact_dir)
        return args, None

    value = str(args.get("run_dir") or "").strip()
    if not value:
        args["run_dir"] = str(artifact_dir)
        return args, None

    supplied = Path(value)
    resolved = supplied.resolve() if supplied.is_absolute() else (workspace / supplied).resolve()
    if not resolved.is_relative_to(workspace):
        return args, (
            f"run_dir {value!r} is outside this agent's workspace. A run_dir "
            f"must be inside {workspace} - pass a relative path such as "
            '"runs/<name>" to point at a directory you created there.'
        )
    args["run_dir"] = str(resolved)
    return args, None


'''


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def locate_worker() -> tuple[object, Path]:
    import src.swarm.worker as worker
    return worker, Path(worker.__file__).resolve()


def state(text: str) -> dict[str, object]:
    return {
        "has_vulnerable_overwrite": VULNERABLE_DISPATCH in text,
        "has_tool_arguments": "def _tool_arguments(" in text,
        "has_fixed_dispatch": "args, run_dir_refusal = _tool_arguments(" in text,
        "has_refusal_dispatch": "if run_dir_refusal is not None:" in text,
        "has_base_tool_import": "from src.agent.tools import BaseTool, ToolRegistry" in text,
    }


def fixed(text: str) -> bool:
    s = state(text)
    return (
        not s["has_vulnerable_overwrite"]
        and s["has_tool_arguments"]
        and s["has_fixed_dispatch"]
        and s["has_refusal_dispatch"]
        and s["has_base_tool_import"]
    )


def smoke(worker_module: object) -> dict[str, object]:
    workspace = Path(tempfile.mkdtemp(prefix="vibe-run-dir-fix-")) / "artifacts" / "backtester"
    workspace.mkdir(parents=True, exist_ok=True)
    declared = SimpleNamespace(parameters={"properties": {"run_dir": {"type": "string"}}})

    args, refusal = worker_module._tool_arguments(declared, {"run_dir": "runs/demo"}, workspace)
    expected = (workspace.resolve() / "runs" / "demo").resolve()
    if refusal is not None or Path(args["run_dir"]).resolve() != expected:
        raise RuntimeError(f"RELATIVE_RUN_DIR_SMOKE_FAILED:{args}:{refusal}")

    _, escape_refusal = worker_module._tool_arguments(declared, {"run_dir": "../../escape"}, workspace)
    if not escape_refusal:
        raise RuntimeError("ESCAPE_GUARD_SMOKE_FAILED")

    undeclared = SimpleNamespace(parameters={"properties": {}})
    args2, refusal2 = worker_module._tool_arguments(undeclared, {"run_dir": "runs/demo"}, workspace)
    if refusal2 is not None or Path(args2["run_dir"]).resolve() != workspace.resolve():
        raise RuntimeError(f"UNDECLARED_PIN_SMOKE_FAILED:{args2}:{refusal2}")

    return {
        "relative_run_dir": "PASS",
        "escape_guard": "PASS",
        "undeclared_tool_pin": "PASS",
    }


def apply() -> dict[str, object]:
    worker, path = locate_worker()
    original = path.read_text(encoding="utf-8")
    before = sha256_text(original)

    if fixed(original):
        reloaded = importlib.reload(worker)
        return {
            "status": "ALREADY_FIXED",
            "upstream_commit": UPSTREAM_COMMIT,
            "worker_path": str(path),
            "sha256": before,
            "state": state(original),
            "smoke": smoke(reloaded),
        }

    checks = {
        "vulnerable_count": original.count(VULNERABLE_DISPATCH),
        "exec_count": original.count(OLD_EXEC),
        "helper_present": "def _tool_arguments(" in original,
        "old_import_count": original.count("from src.agent.tools import ToolRegistry"),
        "preview_marker_count": original.count("def _preview_tool_arguments("),
    }
    if checks != {
        "vulnerable_count": 1,
        "exec_count": 1,
        "helper_present": False,
        "old_import_count": 1,
        "preview_marker_count": 1,
    }:
        raise RuntimeError("UPSTREAM_FIX_PRECONDITION_FAILED:" + json.dumps(checks, sort_keys=True))

    patched = original
    patched = patched.replace(
        "from src.agent.tools import ToolRegistry",
        "from src.agent.tools import BaseTool, ToolRegistry",
        1,
    )
    patched = patched.replace(VULNERABLE_DISPATCH, FIXED_DISPATCH, 1)
    patched = patched.replace(OLD_EXEC, NEW_EXEC, 1)
    patched = patched.replace("def _preview_tool_arguments(", HELPER + "def _preview_tool_arguments(", 1)

    compile(patched, str(path), "exec")
    backup = path.with_name(path.name + ".pre-e30a6427.bak")
    if not backup.exists():
        backup.write_text(original, encoding="utf-8")

    temp_path = path.with_name(path.name + ".cygnus-new")
    temp_path.write_text(patched, encoding="utf-8")
    os.replace(temp_path, path)
    py_compile.compile(str(path), doraise=True)

    after_text = path.read_text(encoding="utf-8")
    if not fixed(after_text):
        raise RuntimeError("UPSTREAM_FIX_POSTCONDITION_FAILED:" + json.dumps(state(after_text), sort_keys=True))

    reloaded = importlib.reload(worker)
    return {
        "status": "PATCHED",
        "upstream_commit": UPSTREAM_COMMIT,
        "worker_path": str(path),
        "backup_path": str(backup),
        "sha256_before": before,
        "sha256_after": sha256_text(after_text),
        "state": state(after_text),
        "smoke": smoke(reloaded),
    }


def check() -> dict[str, object]:
    worker, path = locate_worker()
    text = path.read_text(encoding="utf-8")
    result = {
        "status": "PASS" if fixed(text) else "FAIL",
        "upstream_commit": UPSTREAM_COMMIT,
        "worker_path": str(path),
        "sha256": sha256_text(text),
        "state": state(text),
    }
    if result["status"] == "PASS":
        result["smoke"] = smoke(worker)
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    result = check() if args.check else apply()
    print("VIBE_RUN_DIR_UPSTREAM_FIX=" + str(result["status"]))
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))
    return 0 if result["status"] in {"PASS", "PATCHED", "ALREADY_FIXED"} else 2


if __name__ == "__main__":
    raise SystemExit(main())
