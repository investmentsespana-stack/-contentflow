from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import patch
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import app as bridge


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp).resolve()
        python_exe = root / ".venv" / "Scripts" / "python.exe"
        script = root / "asset_research.py"
        evidence_dir = root / "evidence"
        evidence_path = evidence_dir / "asset-research-cl-test.json"
        python_exe.parent.mkdir(parents=True)
        evidence_dir.mkdir(parents=True)
        python_exe.write_bytes(b"stub")
        script.write_text("# stub", encoding="utf-8")
        evidence = {
            "schema": "cygnus.vibe.asset_research.v1",
            "action": "start",
            "asset": "CL",
            "status": "STARTED",
            "run_id": "run_test_123",
            "mode": "RESEARCH_ONLY",
            "live": False,
            "shell_tools": False,
            "broker_execution": False,
        }
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        stdout = "\n".join([
            "VIBE_ASSET_RESEARCH_START",
            "ASSET=CL",
            "STATUS=STARTED",
            "RUN_ID=run_test_123",
            "MODE=RESEARCH_ONLY",
            "LIVE=false",
            "SHELL_TOOLS=false",
            "BROKER_EXECUTION=false",
            f"EVIDENCE={evidence_path}",
        ])
        completed = subprocess.CompletedProcess(args=[], returncode=0, stdout=stdout.encode(), stderr=b"")

        with (
            patch.object(bridge, "VIBE_ROOT", root),
            patch.object(bridge, "VIBE_PYTHON", python_exe),
            patch.object(bridge, "VIBE_ASSET_SCRIPT", script),
            patch.object(bridge.subprocess, "run", return_value=completed) as run,
        ):
            result = bridge._run_vibe_asset_research({"action": "start", "asset": "CL"})

        assert result["asset"] == "CL"
        assert result["run_id"] == "run_test_123"
        assert result["research_only"] is True
        assert result["live"] is False
        assert result["shell_tools"] is False
        assert result["broker_execution"] is False
        args, kwargs = run.call_args
        assert "--asset" in args[0] and "CL" in args[0]
        assert kwargs["shell"] is False
        assert kwargs["env"]["VIBE_TRADING_ENABLE_SHELL_TOOLS"] == "0"
        assert kwargs["env"]["CYGNUS_RESEARCH_ONLY"] == "1"

        try:
            bridge._run_vibe_asset_research({"action": "start", "asset": "BTC"})
        except RuntimeError as exc:
            assert "ASSET_NOT_ALLOWED" in str(exc)
        else:
            raise AssertionError("unsupported asset was not rejected")

        print("VIBE_ASSET_BRIDGE_GATE_PASS")


if __name__ == "__main__":
    main()
