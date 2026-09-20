from __future__ import annotations

import json
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import patch

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
import app as bridge


class IdleRuntime:
    def is_running(self) -> bool:
        return False


def main() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp).resolve()
        python_exe = root / ".venv" / "Scripts" / "python.exe"
        script = root / "nq6_frozen_vibe_smoke.py"
        evidence_dir = root / "evidence"
        evidence_path = evidence_dir / "nq6-vibe-frozen-smoke-test.json"
        python_exe.parent.mkdir(parents=True)
        evidence_dir.mkdir(parents=True)
        python_exe.write_bytes(b"stub")
        script.write_text("# stub", encoding="utf-8")

        evidence = {
            "mode": "RESEARCH_ONLY",
            "live": False,
            "shell_tools": False,
            "sqx_invoked": False,
            "strategies": [{"name": f"s{i}", "vibe_read_ok": True} for i in range(6)],
        }
        evidence_path.write_text(json.dumps(evidence), encoding="utf-8")
        stdout = "\n".join(
            [
                "VIBE_NQ6_SMOKE_PASS",
                "STRATEGIES=6",
                "IDENTITY_MATCH=6/6",
                "VIBE_READ_FILE=6/6",
                "MODE=RESEARCH_ONLY",
                "LIVE=false",
                "SHELL_TOOLS=false",
                "SQX_INVOKED=false",
                f"EVIDENCE={evidence_path}",
            ]
        )
        completed = subprocess.CompletedProcess(
            args=[], returncode=0, stdout=stdout.encode(), stderr=b""
        )

        with (
            patch.object(bridge, "VIBE_ROOT", root),
            patch.object(bridge, "VIBE_PYTHON", python_exe),
            patch.object(bridge, "VIBE_NQ6_SCRIPT", script),
            patch.object(bridge.subprocess, "run", return_value=completed) as run,
        ):
            result = bridge._run_vibe_nq6_smoke(IdleRuntime())

        assert result["research_only"] is True
        assert result["live"] is False
        assert result["shell_tools"] is False
        assert result["sqx_invoked"] is False
        assert result["strategies"] == 6
        args, kwargs = run.call_args
        assert args[0] == [
            str(python_exe),
            str(script),
            "--mcp-url",
            "http://127.0.0.1:8900/mcp",
        ]
        assert kwargs["shell"] is False
        assert kwargs["env"]["VIBE_TRADING_ENABLE_SHELL_TOOLS"] == "0"
        assert kwargs["env"]["CYGNUS_RESEARCH_ONLY"] == "1"
        print("VIBE_NQ6_BRIDGE_GATE_PASS")


if __name__ == "__main__":
    main()
