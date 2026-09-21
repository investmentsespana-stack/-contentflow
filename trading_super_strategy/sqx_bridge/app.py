from __future__ import annotations

import base64
import csv
import hashlib
import io
import json
import os
import queue
import re
import signal
import socket
import subprocess
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
import keyring
import tkinter as tk
from tkinter import messagebox, ttk

APP_NAME = "Cygnus SQX Bridge"
KEYRING_SERVICE = "CygnusSQXBridge"
CONTROL_URL = "https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/sqx-bridge"
DEFAULT_SQCLI_PATH = r"C:\OI\sqcli.exe"
MAX_ARTIFACT_BYTES = 4 * 1024 * 1024
VIBE_ROOT = Path(r"C:\\Cygnus\\VibeTrading")
VIBE_PYTHON = VIBE_ROOT / ".venv" / "Scripts" / "python.exe"
VIBE_NQ6_SCRIPT = VIBE_ROOT / "nq6_frozen_vibe_smoke.py"
VIBE_ASSET_SCRIPT = VIBE_ROOT / "asset_research.py"
VIBE_MCP_URL = "http://127.0.0.1:8900/mcp"
VIBE_ALLOWED_ASSETS = {"NQ", "ES", "CL", "GC", "DXY"}
VIBE_ASSET_ALIASES = {"DX": "DXY"}
VIBE_ASSET_ACTIONS = {"start", "status", "result"}

READ_ONLY = {
    "cli_help",
    "list_projects",
    "list_databanks",
    "status_project",
    "list_symbols",
    "list_instruments",
    "list_timezones",
    "count_databank",
    "export_databank",
    "list_strategies",
    "get_strategy_stats",
    "save_project_config",
    "run_vibe_nq6_smoke",
    "run_vibe_asset_research",
}
RESEARCH_CONTROL = {
    "run_project",
    "stop_project",
    "pause_project",
    "resume_project",
    "load_project_config",
    "update_data",
    "add_instrument",
    "add_symbol",
    "create_databank",
    "copy_databank",
    "move_databank",
}
ALLOWLIST = READ_ONLY | RESEARCH_CONTROL


def config_dir() -> Path:
    base = Path(os.environ.get("APPDATA") or Path.home())
    p = base / "CygnusSQXBridge"
    p.mkdir(parents=True, exist_ok=True)
    return p


CONFIG_PATH = config_dir() / "config.json"
ARTIFACT_DIR = config_dir() / "artifacts"
CONFIG_EXPORT_DIR = config_dir() / "configs"
ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
CONFIG_EXPORT_DIR.mkdir(parents=True, exist_ok=True)


@dataclass
class BridgeConfig:
    device_id: str
    device_name: str
    sqcli_path: str = DEFAULT_SQCLI_PATH
    allow_project_control: bool = False
    auto_start: bool = True

    @classmethod
    def load(cls) -> "BridgeConfig | None":
        if not CONFIG_PATH.exists():
            return None
        raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        if "sqx_mcp_url" in raw and "sqcli_path" not in raw:
            raw.pop("sqx_mcp_url", None)
            raw["sqcli_path"] = DEFAULT_SQCLI_PATH
        allowed = {k: raw[k] for k in ("device_id", "device_name", "sqcli_path", "allow_project_control", "auto_start") if k in raw}
        return cls(**allowed)

    def save(self) -> None:
        CONFIG_PATH.write_text(json.dumps(self.__dict__, indent=2), encoding="utf-8")


class ControlPlane:
    def __init__(self, token: str):
        self.client = httpx.Client(timeout=20.0)
        self.token = token

    def post(self, body: dict[str, Any]) -> dict[str, Any]:
        r = self.client.post(CONTROL_URL, json=body, headers={"Authorization": f"Bearer {self.token}"})
        r.raise_for_status()
        return r.json()

    @staticmethod
    def pair(code: str, device_name: str) -> dict[str, Any]:
        with httpx.Client(timeout=20.0) as c:
            r = c.post(CONTROL_URL, json={"action": "pair", "code": code, "device_name": device_name})
            r.raise_for_status()
            return r.json()


def _decode(data: bytes) -> str:
    for enc in ("utf-8", "cp1252"):
        try:
            return data.decode(enc)
        except UnicodeDecodeError:
            pass
    return data.decode("utf-8", errors="replace")


_STARTUP_FAILURE_PATTERNS: tuple[tuple[str, str], ...] = (
    ("cannot_start_project", r"cannot\s+start\s+project"),
    ("cannot_start_project_es", r"no\s+se\s+puede\s+iniciar\s+el\s+proyecto"),
    ("unresolved_resources", r"unresolved\s+resources"),
    ("license_failed", r"(?:check\s+license.*fail|license.*failed)"),
    ("missing_resource", r"(?:doesn['’]t\s+exist|not\s+found|missing\s+resource)"),
)

_STARTUP_POSITIVE_PATTERNS: tuple[str, ...] = (
    r"starting\s+project\s+['\"]",
    r"iniciando\s+proyecto\s+['\"]",
)


def _startup_failure_reason(text: str) -> str | None:
    for reason, pattern in _STARTUP_FAILURE_PATTERNS:
        if re.search(pattern, text or "", flags=re.IGNORECASE):
            return reason
    return None


def _startup_marker_seen(text: str) -> bool:
    return any(re.search(pattern, text or "", flags=re.IGNORECASE) for pattern in _STARTUP_POSITIVE_PATTERNS)


def _safe_slug(value: str, fallback: str = "item") -> str:
    slug = re.sub(r"[^A-Za-z0-9._-]+", "_", value.strip()).strip("._")
    return (slug or fallback)[:120]


def _require_text(payload: dict[str, Any], key: str, command: str) -> str:
    value = str(payload.get(key) or "").strip()
    if not value:
        raise RuntimeError(f"{command} requiere payload.{key}")
    return value


def _safe_resource_name(value: str, field: str, command: str) -> str:
    value = str(value or "").strip()
    if not value:
        raise RuntimeError(f"{command} requiere payload.{field}")
    if not re.fullmatch(r"[A-Za-z0-9_@.\- ]+", value):
        raise RuntimeError(f"{command}: {field} contiene caracteres no permitidos")
    return value


def _require_number(payload: dict[str, Any], key: str, command: str, minimum: float = 0.0) -> float:
    raw = payload.get(key)
    try:
        value = float(raw)
    except (TypeError, ValueError) as exc:
        raise RuntimeError(f"{command} requiere payload.{key} numérico") from exc
    if value <= minimum:
        raise RuntimeError(f"{command}: payload.{key} debe ser > {minimum}")
    return value


def _project_from_payload(name: str, payload: dict[str, Any]) -> str:
    project = str(payload.get("project") or payload.get("name") or "").strip()
    if not project:
        raise RuntimeError(f"{name} requiere payload.project")
    return project


def _databank_from_payload(name: str, payload: dict[str, Any]) -> str:
    return _require_text(payload, "databank", name)


def _run_sqcli(path: str, args: list[str], timeout: int = 180) -> dict[str, Any]:
    exe = Path(path)
    if not exe.is_file():
        raise RuntimeError(f"sqcli.exe no encontrado: {path}")
    cp = subprocess.run(
        [str(exe), *args],
        cwd=str(exe.parent),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=timeout,
        shell=False,
    )
    stdout = _decode(cp.stdout).strip()
    stderr = _decode(cp.stderr).strip()
    combined = "\n".join(x for x in (stdout, stderr) if x).strip()
    if cp.returncode != 0:
        hint = " Cierra StrategyQuant X gráfico antes de usar el bridge." if "another instance" in combined.lower() else ""
        raise RuntimeError(f"SQCLI rc={cp.returncode}: {combined[:4000]}{hint}")
    return {"returncode": cp.returncode, "stdout": stdout, "stderr": stderr}


class SqCliRuntime:
    """Owns long-running Builder/Custom Project processes so the bridge stays responsive."""

    def __init__(self, sqcli_path: str):
        self.sqcli_path = sqcli_path
        self.lock = threading.RLock()
        self.active_process: subprocess.Popen[bytes] | None = None
        self.active_project: str | None = None
        self.active_started_at: float | None = None
        self.active_output: list[str] = []
        self.last_run: dict[str, Any] | None = None

    def _process_running(self) -> bool:
        return self.active_process is not None and self.active_process.poll() is None

    def is_running(self) -> bool:
        with self.lock:
            return self._process_running()

    def _reader(self, proc: subprocess.Popen[bytes], project: str) -> None:
        lines: list[str] = []
        try:
            if proc.stdout is not None:
                while True:
                    chunk = proc.stdout.readline()
                    if not chunk:
                        break
                    line = _decode(chunk).rstrip()
                    lines.append(line)
                    if len(lines) > 2500:
                        lines = lines[-2000:]
                    with self.lock:
                        if self.active_process is proc:
                            self.active_output = list(lines)
        finally:
            rc = proc.wait()
            with self.lock:
                if self.active_process is proc:
                    elapsed = max(0.0, time.time() - (self.active_started_at or time.time()))
                    self.last_run = {
                        "project": project,
                        "returncode": rc,
                        "elapsed_seconds": round(elapsed, 1),
                        "stdout_tail": "\n".join(lines[-160:])[-12000:],
                        "completed_at_epoch": time.time(),
                    }

    def start_project(self, project: str) -> dict[str, Any]:
        exe = Path(self.sqcli_path)
        if not exe.is_file():
            raise RuntimeError(f"sqcli.exe no encontrado: {self.sqcli_path}")
        with self.lock:
            if self._process_running():
                raise RuntimeError(f"SQX_BUSY_ACTIVE_RUN:{self.active_project}")
            creationflags = subprocess.CREATE_NEW_PROCESS_GROUP if os.name == "nt" else 0
            proc = subprocess.Popen(
                [str(exe), "-project", "action=start", f"name={project}"],
                cwd=str(exe.parent),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                shell=False,
                creationflags=creationflags,
            )
            self.active_process = proc
            self.active_project = project
            self.active_started_at = time.time()
            self.active_output = []
            self.last_run = None
            threading.Thread(target=self._reader, args=(proc, project), daemon=True).start()

        deadline = time.monotonic() + 90.0
        positive_seen_at: float | None = None
        while time.monotonic() < deadline:
            with self.lock:
                output = "\n".join(self.active_output[-260:])

            failure = _startup_failure_reason(output)
            if failure:
                if proc.poll() is None:
                    try:
                        proc.terminate()
                        proc.wait(timeout=5)
                    except Exception:
                        try:
                            proc.kill()
                        except Exception:
                            pass
                raise RuntimeError(f"SQX_STARTUP_REJECTED:{failure}: {output[-6000:]}")

            if positive_seen_at is None and _startup_marker_seen(output):
                positive_seen_at = time.monotonic()

            rc = proc.poll()
            if rc is not None:
                if rc != 0:
                    raise RuntimeError(f"SQCLI start falló rc={rc}: {output[-6000:]}")
                raise RuntimeError(f"SQX_STARTUP_EXITED_BEFORE_CERTIFICATION: {output[-6000:]}")

            if positive_seen_at is not None and time.monotonic() - positive_seen_at >= 8.0:
                gate_seconds = round(time.time() - (self.active_started_at or time.time()), 1)
                return {
                    "returncode": 0,
                    "stdout": f"SQX startup certified for {project}\n{output[-6000:]}",
                    "stderr": "",
                    "started": True,
                    "startup_verified": True,
                    "startup_gate_seconds": gate_seconds,
                    "pid": proc.pid,
                    "project": project,
                }
            time.sleep(0.25)

        with self.lock:
            output = "\n".join(self.active_output[-260:])
        if proc.poll() is None:
            try:
                proc.terminate()
                proc.wait(timeout=5)
            except Exception:
                try:
                    proc.kill()
                except Exception:
                    pass
        raise RuntimeError(f"SQX_STARTUP_TIMEOUT_UNCERTIFIED: {output[-6000:]}")

    def status(self, project: str | None = None) -> dict[str, Any] | None:
        with self.lock:
            if self.active_process is None:
                return None
            if project and self.active_project != project:
                return None
            proc = self.active_process
            running = proc.poll() is None
            elapsed = max(0.0, time.time() - (self.active_started_at or time.time()))
            return {
                "project": self.active_project,
                "running": running,
                "pid": proc.pid,
                "returncode": None if running else proc.returncode,
                "elapsed_seconds": round(elapsed, 1),
                "stdout_tail": "\n".join(self.active_output[-120:])[-10000:],
            }

    def stop_project(self, project: str) -> dict[str, Any]:
        with self.lock:
            proc = self.active_process
            active_project = self.active_project
        if proc is None or proc.poll() is not None or active_project != project:
            return _run_sqcli(self.sqcli_path, ["-project", "action=stop", f"name={project}"], timeout=180)

        method = "terminate"
        try:
            if os.name == "nt":
                proc.send_signal(signal.CTRL_BREAK_EVENT)
                method = "CTRL_BREAK"
                proc.wait(timeout=8)
            else:
                proc.terminate()
                proc.wait(timeout=8)
        except Exception:
            try:
                proc.terminate()
                proc.wait(timeout=8)
                method = "terminate"
            except Exception:
                proc.kill()
                proc.wait(timeout=5)
                method = "kill"
        snap = self.status(project) or {}
        return {
            "returncode": 0,
            "stdout": f"Stopped active SQX research process for {project} via {method}",
            "stderr": "",
            "stopped": True,
            "stop_method": method,
            "runtime": snap,
        }

    def health(self) -> dict[str, Any]:
        with self.lock:
            active = self.status()
            return {"active_run": active, "last_run": self.last_run}


def _require_idle(runtime: SqCliRuntime, command: str) -> None:
    if runtime.is_running():
        snap = runtime.status() or {}
        raise RuntimeError(f"SQX_BUSY_ACTIVE_RUN:{snap.get('project')} - {command} requiere motor libre")


def _read_artifact(path: Path) -> dict[str, Any]:
    data = path.read_bytes()
    result: dict[str, Any] = {
        "artifact_name": path.name,
        "artifact_size": len(data),
        "artifact_sha256": hashlib.sha256(data).hexdigest(),
    }
    if len(data) <= MAX_ARTIFACT_BYTES:
        result["content_b64"] = base64.b64encode(data).decode("ascii")
    else:
        result["content_truncated"] = True
        result["preview"] = _decode(data[:200000])
    return result


def _export_databank_file(cfg: BridgeConfig, runtime: SqCliRuntime, project: str, databank: str) -> tuple[Path, dict[str, Any]]:
    _require_idle(runtime, "export_databank")
    filename = f"{_safe_slug(project)}__{_safe_slug(databank)}__{int(time.time())}.csv"
    path = ARTIFACT_DIR / filename
    result = _run_sqcli(
        cfg.sqcli_path,
        ["-databank", "action=export", f"project={project}", f"name={databank}", f"file={path}"],
        timeout=600,
    )
    if not path.exists():
        raise RuntimeError("SQX no produjo el CSV de databank esperado")
    return path, result


def _csv_rows(path: Path) -> tuple[list[str], list[dict[str, str]], str]:
    raw = path.read_bytes()
    text = _decode(raw)
    sample = text[:8192]
    try:
        dialect = csv.Sniffer().sniff(sample, delimiters=",;\t")
    except csv.Error:
        dialect = csv.excel
    reader = csv.DictReader(io.StringIO(text), dialect=dialect)
    rows: list[dict[str, str]] = []
    for row in reader:
        rows.append({str(k): ("" if v is None else str(v)) for k, v in row.items() if k is not None})
        if len(rows) >= 10000:
            break
    return list(reader.fieldnames or []), rows, text


def _strategy_name_key(headers: list[str]) -> str | None:
    preferred = ("strategy", "strategy name", "name")
    lower = {h.lower().strip(): h for h in headers}
    for p in preferred:
        if p in lower:
            return lower[p]
    for h in headers:
        if "strateg" in h.lower() or h.lower().strip().endswith("name"):
            return h
    return headers[0] if headers else None



def _run_vibe_nq6_smoke(runtime: SqCliRuntime) -> dict[str, Any]:
    """Run one fixed, research-only Vibe smoke test. No arbitrary command input."""
    _require_idle(runtime, "run_vibe_nq6_smoke")

    python_exe = VIBE_PYTHON.resolve()
    script = VIBE_NQ6_SCRIPT.resolve()
    root = VIBE_ROOT.resolve()
    if not python_exe.is_file():
        raise RuntimeError(f"VIBE_PYTHON_MISSING:{python_exe}")
    if not script.is_file():
        raise RuntimeError(f"VIBE_NQ6_SCRIPT_MISSING:{script}")
    if root not in python_exe.parents or root not in script.parents:
        raise RuntimeError("VIBE_FIXED_PATH_POLICY_FAIL")

    env = os.environ.copy()
    env["VIBE_TRADING_ENABLE_SHELL_TOOLS"] = "0"
    env["CYGNUS_RESEARCH_ONLY"] = "1"

    cp = subprocess.run(
        [str(python_exe), str(script), "--mcp-url", VIBE_MCP_URL],
        cwd=str(root),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=600,
        shell=False,
        env=env,
    )
    stdout = _decode(cp.stdout).strip()
    stderr = _decode(cp.stderr).strip()
    if cp.returncode != 0:
        raise RuntimeError(
            f"VIBE_NQ6_SMOKE_PROCESS_FAIL rc={cp.returncode}: {(stderr or stdout)[-6000:]}"
        )

    required_markers = (
        "VIBE_NQ6_SMOKE_PASS",
        "STRATEGIES=6",
        "IDENTITY_MATCH=6/6",
        "VIBE_READ_FILE=6/6",
        "MODE=RESEARCH_ONLY",
        "LIVE=false",
        "SHELL_TOOLS=false",
        "SQX_INVOKED=false",
    )
    missing = [marker for marker in required_markers if marker not in stdout]
    if missing:
        raise RuntimeError("VIBE_NQ6_SMOKE_MARKERS_MISSING:" + ",".join(missing))

    evidence_value = ""
    for line in stdout.splitlines():
        if line.startswith("EVIDENCE="):
            evidence_value = line.split("=", 1)[1].strip()
            break
    if not evidence_value:
        raise RuntimeError("VIBE_NQ6_EVIDENCE_PATH_MISSING")

    evidence_path = Path(evidence_value).resolve()
    evidence_root = (root / "evidence").resolve()
    if evidence_path != evidence_root and evidence_root not in evidence_path.parents:
        raise RuntimeError(f"VIBE_NQ6_EVIDENCE_PATH_BLOCKED:{evidence_path}")
    if not evidence_path.is_file():
        raise RuntimeError(f"VIBE_NQ6_EVIDENCE_FILE_MISSING:{evidence_path}")

    try:
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise RuntimeError(f"VIBE_NQ6_EVIDENCE_INVALID_JSON:{exc}") from exc

    if evidence.get("mode") != "RESEARCH_ONLY":
        raise RuntimeError("VIBE_NQ6_POLICY_FAIL:mode")
    if evidence.get("live") is not False:
        raise RuntimeError("VIBE_NQ6_POLICY_FAIL:live")
    if evidence.get("shell_tools") is not False:
        raise RuntimeError("VIBE_NQ6_POLICY_FAIL:shell_tools")
    if evidence.get("sqx_invoked") is not False:
        raise RuntimeError("VIBE_NQ6_POLICY_FAIL:sqx_invoked")

    strategies = evidence.get("strategies")
    if not isinstance(strategies, list) or len(strategies) != 6:
        raise RuntimeError("VIBE_NQ6_POLICY_FAIL:strategy_count")
    if not all(isinstance(item, dict) and bool(item.get("vibe_read_ok")) for item in strategies):
        raise RuntimeError("VIBE_NQ6_POLICY_FAIL:vibe_read")

    return {
        "returncode": 0,
        "stdout": stdout,
        "stderr": stderr,
        "research_only": True,
        "live": False,
        "shell_tools": False,
        "sqx_invoked": False,
        "strategies": 6,
        "identity_match": "6/6",
        "vibe_read_file": "6/6",
        "evidence_path": str(evidence_path),
        "evidence": evidence,
    }


def _run_vibe_asset_research(payload: dict[str, Any]) -> dict[str, Any]:
    """Run fixed, allowlisted multi-asset Vibe research. No arbitrary prompt or shell input."""
    python_exe = VIBE_PYTHON.resolve()
    script = VIBE_ASSET_SCRIPT.resolve()
    root = VIBE_ROOT.resolve()
    if not python_exe.is_file():
        raise RuntimeError(f"VIBE_PYTHON_MISSING:{python_exe}")
    if not script.is_file():
        raise RuntimeError(f"VIBE_ASSET_SCRIPT_MISSING:{script}")
    if root not in python_exe.parents or root not in script.parents:
        raise RuntimeError("VIBE_FIXED_PATH_POLICY_FAIL")

    action = str(payload.get("action") or "start").strip().lower()
    if action not in VIBE_ASSET_ACTIONS:
        raise RuntimeError(f"VIBE_ACTION_NOT_ALLOWED:{action}")

    args = [str(python_exe), str(script), "--action", action, "--mcp-url", VIBE_MCP_URL]
    asset = ""
    run_id = ""
    if action == "start":
        asset = str(payload.get("asset") or "").strip().upper()
        asset = VIBE_ASSET_ALIASES.get(asset, asset)
        if asset not in VIBE_ALLOWED_ASSETS:
            raise RuntimeError(f"ASSET_NOT_ALLOWED:{asset}")
        args.extend(["--asset", asset])
    else:
        run_id = str(payload.get("run_id") or "").strip()
        if not re.fullmatch(r"[A-Za-z0-9._:-]{1,160}", run_id):
            raise RuntimeError("INVALID_RUN_ID")
        args.extend(["--run-id", run_id])

    env = os.environ.copy()
    env["VIBE_TRADING_ENABLE_SHELL_TOOLS"] = "0"
    env["CYGNUS_RESEARCH_ONLY"] = "1"

    cp = subprocess.run(
        args,
        cwd=str(root),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=240,
        shell=False,
        env=env,
    )
    stdout = _decode(cp.stdout).strip()
    stderr = _decode(cp.stderr).strip()
    if cp.returncode != 0:
        raise RuntimeError(
            f"VIBE_ASSET_RESEARCH_PROCESS_FAIL rc={cp.returncode}: {(stderr or stdout)[-8000:]}"
        )

    required = [
        "MODE=RESEARCH_ONLY",
        "LIVE=false",
        "SHELL_TOOLS=false",
        "BROKER_EXECUTION=false",
        "EVIDENCE=",
    ]
    if action == "start":
        required.extend(["VIBE_ASSET_RESEARCH_START", f"ASSET={asset}", "STATUS=STARTED", "RUN_ID="])
    else:
        required.extend(["VIBE_ASSET_RESEARCH_CHECK", f"ACTION={action}", f"RUN_ID={run_id}"])
    missing = [m for m in required if m not in stdout]
    if missing:
        raise RuntimeError("VIBE_ASSET_MARKERS_MISSING:" + ",".join(missing))

    evidence_value = ""
    stdout_run_id = run_id
    for line in stdout.splitlines():
        if line.startswith("EVIDENCE="):
            evidence_value = line.split("=", 1)[1].strip()
        elif action == "start" and line.startswith("RUN_ID="):
            stdout_run_id = line.split("=", 1)[1].strip()

    if action == "start" and not re.fullmatch(r"[A-Za-z0-9._:-]{1,160}", stdout_run_id or ""):
        raise RuntimeError("VIBE_ASSET_RUN_ID_MISSING")
    if not evidence_value:
        raise RuntimeError("VIBE_ASSET_EVIDENCE_PATH_MISSING")

    evidence_path = Path(evidence_value).resolve()
    evidence_root = (root / "evidence").resolve()
    if evidence_path != evidence_root and evidence_root not in evidence_path.parents:
        raise RuntimeError(f"VIBE_ASSET_EVIDENCE_PATH_BLOCKED:{evidence_path}")
    if not evidence_path.is_file():
        raise RuntimeError(f"VIBE_ASSET_EVIDENCE_FILE_MISSING:{evidence_path}")
    try:
        evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
    except Exception as exc:
        raise RuntimeError(f"VIBE_ASSET_EVIDENCE_INVALID_JSON:{exc}") from exc

    if evidence.get("mode") != "RESEARCH_ONLY":
        raise RuntimeError("VIBE_ASSET_POLICY_FAIL:mode")
    if evidence.get("live") is not False:
        raise RuntimeError("VIBE_ASSET_POLICY_FAIL:live")
    if evidence.get("shell_tools") is not False:
        raise RuntimeError("VIBE_ASSET_POLICY_FAIL:shell_tools")
    if evidence.get("broker_execution") is not False:
        raise RuntimeError("VIBE_ASSET_POLICY_FAIL:broker_execution")

    return {
        "returncode": 0,
        "stdout": stdout,
        "stderr": stderr,
        "research_only": True,
        "live": False,
        "shell_tools": False,
        "broker_execution": False,
        "action": action,
        "asset": asset or None,
        "run_id": stdout_run_id or None,
        "evidence_path": str(evidence_path),
        "evidence": evidence,
    }


def sqx_call(cfg: BridgeConfig, runtime: SqCliRuntime, name: str, payload: dict[str, Any]) -> dict[str, Any]:
    if name not in ALLOWLIST:
        raise RuntimeError(f"Comando bloqueado por allowlist: {name}")
    if name in RESEARCH_CONTROL and not cfg.allow_project_control:
        raise RuntimeError("Control autónomo de investigación está deshabilitado localmente")

    extra: dict[str, Any] = {}

    if name == "cli_help":
        _require_idle(runtime, name)
        result = _run_sqcli(cfg.sqcli_path, ["-h"], timeout=180)

    elif name == "list_projects":
        _require_idle(runtime, name)
        result = _run_sqcli(cfg.sqcli_path, ["-project", "action=list"])

    elif name == "list_databanks":
        _require_idle(runtime, name)
        project = _project_from_payload(name, payload)
        result = _run_sqcli(cfg.sqcli_path, ["-databank", "action=list", f"project={project}"])

    elif name == "status_project":
        project = _project_from_payload(name, payload)
        active = runtime.status(project)
        if active and active.get("running"):
            result = {
                "returncode": 0,
                "stdout": f"Project {project} is RUNNING under Cygnus bridge\n{active.get('stdout_tail', '')}",
                "stderr": "",
            }
            extra["runtime"] = active
        else:
            result = _run_sqcli(cfg.sqcli_path, ["-project", "action=status", f"name={project}"])

    elif name == "list_symbols":
        _require_idle(runtime, name)
        result = _run_sqcli(cfg.sqcli_path, ["-symbol", "action=list"])

    elif name == "list_instruments":
        _require_idle(runtime, name)
        result = _run_sqcli(cfg.sqcli_path, ["-instrument", "action=list"])

    elif name == "list_timezones":
        _require_idle(runtime, name)
        result = _run_sqcli(cfg.sqcli_path, ["-data", "action=timezones"])

    elif name == "count_databank":
        _require_idle(runtime, name)
        project = _project_from_payload(name, payload)
        databank = _databank_from_payload(name, payload)
        result = _run_sqcli(cfg.sqcli_path, ["-databank", "action=count", f"project={project}", f"name={databank}"])

    elif name in {"export_databank", "list_strategies", "get_strategy_stats"}:
        project = _project_from_payload(name, payload)
        databank = _databank_from_payload(name, payload)
        path, result = _export_databank_file(cfg, runtime, project, databank)
        headers, rows, text = _csv_rows(path)
        extra.update(_read_artifact(path))
        extra["csv_headers"] = headers
        extra["row_count_parsed"] = len(rows)
        key = _strategy_name_key(headers)
        if name == "list_strategies":
            extra["strategies"] = [r.get(key, "") for r in rows if key and r.get(key, "")][:5000]
        elif name == "get_strategy_stats":
            strategy = _require_text(payload, "strategy", name)
            match = None
            for row in rows:
                if key and row.get(key, "").strip() == strategy:
                    match = row
                    break
                if any(str(v).strip() == strategy for v in row.values()):
                    match = row
                    break
            if match is None:
                raise RuntimeError(f"Estrategia no encontrada en export CSV: {strategy}")
            extra["strategy"] = strategy
            extra["stats"] = match
        else:
            extra["csv_preview"] = text[:200000]

    elif name == "save_project_config":
        _require_idle(runtime, name)
        project = _project_from_payload(name, payload)
        path = CONFIG_EXPORT_DIR / f"{_safe_slug(project)}__{int(time.time())}.cfx"
        result = _run_sqcli(cfg.sqcli_path, ["-project", "action=saveconfig", f"name={project}", f"file={path}"], timeout=300)
        if not path.exists():
            raise RuntimeError("SQX no produjo el archivo de configuración esperado")
        extra.update(_read_artifact(path))

    elif name == "load_project_config":
        _require_idle(runtime, name)
        project = _project_from_payload(name, payload)
        encoded = _require_text(payload, "config_b64", name)
        try:
            data = base64.b64decode(encoded, validate=True)
        except Exception as exc:
            raise RuntimeError(f"config_b64 inválido: {exc}") from exc
        if not data or len(data) > MAX_ARTIFACT_BYTES:
            raise RuntimeError(f"Configuración fuera de límite 1..{MAX_ARTIFACT_BYTES} bytes")
        path = CONFIG_EXPORT_DIR / f"load__{_safe_slug(project)}__{int(time.time())}.cfx"
        path.write_bytes(data)
        extra["config_sha256"] = hashlib.sha256(data).hexdigest()
        extra["config_size"] = len(data)

        if bool(payload.get("replace_existing")):
            if "/" in project or "\\" in project or project in {".", ".."}:
                raise RuntimeError("Nombre de proyecto no permitido para replace_existing")
            sqx_root = Path(cfg.sqcli_path).resolve().parent
            destination = sqx_root / "user" / "projects" / project / "project.cfx"
            if not destination.is_file():
                raise RuntimeError(f"project.cfx existente no encontrado: {destination}")
            previous = destination.read_bytes()
            backup = ARTIFACT_DIR / f"backup__{_safe_slug(project)}__{int(time.time())}.cfx"
            backup.write_bytes(previous)
            temp = destination.with_name("project.cfx.cygnus_tmp")
            temp.write_bytes(data)
            os.replace(temp, destination)
            extra["replace_existing"] = True
            extra["backup_artifact_name"] = backup.name
            extra["backup_sha256"] = hashlib.sha256(previous).hexdigest()
            extra["destination"] = str(destination)
            result = {
                "returncode": 0,
                "stdout": f"Replaced existing project.cfx with verified backup: {project}",
                "stderr": "",
            }
        else:
            result = _run_sqcli(cfg.sqcli_path, ["-project", "action=loadconfig", f"name={project}", f"file={path}"], timeout=300)

    elif name == "run_vibe_nq6_smoke":
        if payload:
            raise RuntimeError("run_vibe_nq6_smoke no acepta payload; comando fijo y fail-closed")
        result = _run_vibe_nq6_smoke(runtime)

    elif name == "run_vibe_asset_research":
        result = _run_vibe_asset_research(payload)

    elif name == "run_project":
        project = _project_from_payload(name, payload)
        result = runtime.start_project(project)

    elif name == "stop_project":
        project = _project_from_payload(name, payload)
        result = runtime.stop_project(project)

    elif name in {"pause_project", "resume_project"}:
        project = _project_from_payload(name, payload)
        action = "pause" if name == "pause_project" else "resume"
        result = _run_sqcli(cfg.sqcli_path, ["-project", f"action={action}", f"name={project}"], timeout=180)

    elif name == "add_instrument":
        _require_idle(runtime, name)
        instrument = _safe_resource_name(payload.get("instrument"), "instrument", name)
        description = str(payload.get("description") or "History data instrument").strip()
        if not re.fullmatch(r"[A-Za-z0-9_@.\- ]+", description):
            raise RuntimeError("add_instrument: description contiene caracteres no permitidos")
        pointvalue = _require_number(payload, "pointvalue", name)
        ticksize = _require_number(payload, "ticksize", name)
        tickstep = _require_number(payload, "tickstep", name)
        defaultspread = float(payload.get("defaultspread", 2.0))
        datatype = str(payload.get("datatype") or "futures").strip().lower()
        if datatype not in {"stock", "futures", "forex", "cfds", "etf", "index", "crypto"}:
            raise RuntimeError(f"add_instrument: datatype no permitido: {datatype}")
        result = _run_sqcli(
            cfg.sqcli_path,
            [
                "-instrument",
                "action=add",
                f"instrument={instrument}",
                f"description={description}",
                f"pointvalue={pointvalue:g}",
                f"ticksize={ticksize:g}",
                f"tickstep={tickstep:g}",
                f"defaultspread={defaultspread:g}",
                f"datatype={datatype}",
            ],
            timeout=300,
        )

    elif name == "add_symbol":
        _require_idle(runtime, name)
        symbol = _safe_resource_name(payload.get("symbol"), "symbol", name)
        instrument = _safe_resource_name(payload.get("instrument"), "instrument", name)
        datasource = str(payload.get("datasource") or "file").strip().lower()
        datatype = str(payload.get("datatype") or "M1").strip().upper()
        bartype = str(payload.get("bartype") or "endofbar").strip().lower()
        if datasource not in {"file", "dukascopy", "darwinex", "crypto", "yahoo"}:
            raise RuntimeError(f"add_symbol: datasource no permitido: {datasource}")
        if datatype not in {"M1", "TICK"}:
            raise RuntimeError(f"add_symbol: datatype no permitido: {datatype}")
        if bartype not in {"startofbar", "endofbar"}:
            raise RuntimeError(f"add_symbol: bartype no permitido: {bartype}")
        result = _run_sqcli(
            cfg.sqcli_path,
            [
                "-symbol",
                "action=add",
                f"symbols={symbol}",
                f"instrument={instrument}",
                f"datasource={datasource}",
                f"datatype={datatype}",
                f"bartype={bartype}",
            ],
            timeout=300,
        )

    elif name == "update_data":
        _require_idle(runtime, name)
        symbols = payload.get("symbols")
        if isinstance(symbols, str):
            symbol_list = [x.strip() for x in symbols.split(",") if x.strip()]
        elif isinstance(symbols, list):
            symbol_list = [str(x).strip() for x in symbols if str(x).strip()]
        else:
            symbol_list = []
        if not symbol_list:
            raise RuntimeError("update_data requiere payload.symbols explícito")
        for symbol in symbol_list:
            if not re.fullmatch(r"[A-Za-z0-9_@.\-]+", symbol):
                raise RuntimeError(f"Símbolo no permitido: {symbol}")
        result = _run_sqcli(cfg.sqcli_path, ["-data", "action=update", f"symbols={','.join(symbol_list)}"], timeout=3600)

    elif name == "create_databank":
        _require_idle(runtime, name)
        project = _project_from_payload(name, payload)
        databank = _databank_from_payload(name, payload)
        result = _run_sqcli(cfg.sqcli_path, ["-databank", "action=create", f"project={project}", f"name={databank}"])

    elif name in {"copy_databank", "move_databank"}:
        _require_idle(runtime, name)
        project = _project_from_payload(name, payload)
        databank = _databank_from_payload(name, payload)
        dest_project = _require_text(payload, "dest_project", name)
        dest_databank = _require_text(payload, "dest_databank", name)
        action = "copy" if name == "copy_databank" else "move"
        result = _run_sqcli(
            cfg.sqcli_path,
            [
                "-databank",
                f"action={action}",
                f"project={project}",
                f"name={databank}",
                f"destproject={dest_project}",
                f"destdatabank={dest_databank}",
            ],
            timeout=600,
        )

    else:
        raise RuntimeError(f"Comando no implementado: {name}")

    return {
        "transport": "fixed_vibe_research_process" if name in {"run_vibe_nq6_smoke", "run_vibe_asset_research"} else "sqcli_process",
        "sqcli_path": cfg.sqcli_path,
        "command": name,
        **result,
        **extra,
    }


class BridgeWorker(threading.Thread):
    def __init__(self, cfg: BridgeConfig, token: str, events: queue.Queue):
        super().__init__(daemon=True)
        self.cfg = cfg
        self.events = events
        self.stop_event = threading.Event()
        self.control = ControlPlane(token)
        self.last_heartbeat = 0.0
        self.last_probe = 0.0
        self.cached_probe_excerpt = ""
        self.runtime = SqCliRuntime(cfg.sqcli_path)

    def emit(self, kind: str, text: str, **extra: Any) -> None:
        self.events.put({"kind": kind, "text": text, **extra})

    def stop(self) -> None:
        self.stop_event.set()

    def _heartbeat(self) -> None:
        runtime_health = self.runtime.health()
        active = runtime_health.get("active_run")
        if active and active.get("running"):
            sqx_ok = True
            probe_excerpt = f"active:{active.get('project')} pid={active.get('pid')} elapsed={active.get('elapsed_seconds')}s"
        else:
            # Heartbeats must not restart SQX every 30 seconds. A cached probe
            # is explicitly timestamped; on-demand commands still run afresh.
            if not self.last_probe or time.monotonic() - self.last_probe >= 300:
                self.last_probe = 0.0
                self.cached_probe_excerpt = ""
                probe = sqx_call(self.cfg, self.runtime, "list_projects", {})
                self.cached_probe_excerpt = probe.get("stdout", "")[:1200]
                self.last_probe = time.monotonic()
            sqx_ok = True
            probe_excerpt = self.cached_probe_excerpt
        health = {
            "hostname": socket.gethostname(),
            "transport": "sqcli_process",
            "bridge_version": "142-autonomy-v6-vibe-multi-asset",
            "sqcli_path": self.cfg.sqcli_path,
            "sqx_cli_ok": sqx_ok,
            "capabilities": sorted(ALLOWLIST),
            "project_control_enabled": self.cfg.allow_project_control,
            "probe_excerpt": probe_excerpt,
            "probe_age_seconds": round(time.monotonic() - self.last_probe, 1) if self.last_probe else None,
            "probe_interval_seconds": 300,
            **runtime_health,
        }
        self.control.post({"action": "heartbeat", "health": health})
        self.last_heartbeat = time.time()
        self.emit("health", "SQX CLI conectado", tools=sorted(ALLOWLIST))

    def run(self) -> None:
        self.emit("state", "Bridge iniciado")
        while not self.stop_event.is_set():
            try:
                if time.time() - self.last_heartbeat > 30:
                    self._heartbeat()

                claimed = self.control.post({"action": "claim"})
                command = claimed.get("command")
                if not command:
                    time.sleep(2)
                    continue
                ctype = str(command.get("command_type", ""))
                payload = command.get("payload") or {}
                cid = command.get("id")
                nonce = command.get("claim_nonce")
                self.emit("command", f"Ejecutando {ctype}", command_id=cid)
                try:
                    result = sqx_call(self.cfg, self.runtime, ctype, payload)
                    self.control.post({"action": "complete", "command_id": cid, "claim_nonce": nonce, "success": True, "result": result})
                    self.emit("command", f"Completado {ctype}", command_id=cid)
                except Exception as exc:
                    self.control.post({"action": "complete", "command_id": cid, "claim_nonce": nonce, "success": False, "error": str(exc)})
                    self.emit("error", f"{ctype}: {exc}", command_id=cid)
            except Exception as exc:
                self.emit("error", str(exc))
                time.sleep(5)
        self.emit("state", "Bridge detenido")


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_NAME)
        self.geometry("760x520")
        self.minsize(680, 450)
        self.events: queue.Queue = queue.Queue()
        self.worker: BridgeWorker | None = None
        self.cfg = BridgeConfig.load()
        self.token = ""
        self._build_ui()
        self.after(250, self._drain_events)
        if self.cfg:
            self.token = keyring.get_password(KEYRING_SERVICE, self.cfg.device_id) or ""
            self._load_cfg_to_ui()
            if self.token and self.cfg.auto_start:
                self.start_bridge()
            elif not self.token:
                self._log("No se encontró token local; empareja de nuevo.")
        else:
            self.after(300, self.open_setup)

    def _build_ui(self) -> None:
        pad = {"padx": 12, "pady": 8}
        top = ttk.Frame(self)
        top.pack(fill="x", **pad)
        ttk.Label(top, text="Cygnus SQX Bridge · Build 142 · Autonomy v2", font=("Segoe UI", 15, "bold")).pack(side="left")
        self.status_var = tk.StringVar(value="No conectado")
        ttk.Label(top, textvariable=self.status_var).pack(side="right")

        info = ttk.LabelFrame(self, text="Conexión")
        info.pack(fill="x", **pad)
        self.device_var = tk.StringVar(value="—")
        self.path_var = tk.StringVar(value=DEFAULT_SQCLI_PATH)
        self.tools_var = tk.StringVar(value="—")
        for i, (label, var) in enumerate(
            (("Dispositivo", self.device_var), ("SQCLI", self.path_var), ("Capacidades", self.tools_var))
        ):
            ttk.Label(info, text=label, width=14).grid(row=i, column=0, sticky="w", padx=8, pady=4)
            ttk.Label(info, textvariable=var, wraplength=570).grid(row=i, column=1, sticky="w", padx=8, pady=4)

        buttons = ttk.Frame(self)
        buttons.pack(fill="x", **pad)
        ttk.Button(buttons, text="Configurar / Emparejar", command=self.open_setup).pack(side="left", padx=4)
        ttk.Button(buttons, text="Probar SQX", command=self.test_sqx).pack(side="left", padx=4)
        ttk.Button(buttons, text="Iniciar", command=self.start_bridge).pack(side="left", padx=4)
        ttk.Button(buttons, text="Detener", command=self.stop_bridge).pack(side="left", padx=4)

        self.control_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(
            self,
            text="Permitir control autónomo de investigación (start/stop/config/data/databanks)",
            variable=self.control_var,
            command=self._save_control_flag,
        ).pack(anchor="w", padx=18, pady=4)

        logframe = ttk.LabelFrame(self, text="Actividad")
        logframe.pack(fill="both", expand=True, **pad)
        self.log = tk.Text(logframe, height=14, wrap="word", state="disabled")
        self.log.pack(fill="both", expand=True, padx=6, pady=6)

    def _log(self, text: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", f"[{time.strftime('%H:%M:%S')}] {text}\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def _load_cfg_to_ui(self) -> None:
        if not self.cfg:
            return
        self.device_var.set(f"{self.cfg.device_name} · {self.cfg.device_id[:8]}")
        self.path_var.set(self.cfg.sqcli_path)
        self.control_var.set(self.cfg.allow_project_control)
        self.tools_var.set(", ".join(sorted(ALLOWLIST)))

    def open_setup(self) -> None:
        win = tk.Toplevel(self)
        win.title("Configurar SQX Bridge")
        win.geometry("620x320")
        win.grab_set()
        device = tk.StringVar(value=self.cfg.device_name if self.cfg else socket.gethostname())
        path = tk.StringVar(value=self.cfg.sqcli_path if self.cfg else DEFAULT_SQCLI_PATH)
        code = tk.StringVar(value="")
        for i, (label, var) in enumerate(
            (("Nombre del PC", device), ("Ruta sqcli.exe", path), ("Código de emparejamiento", code))
        ):
            ttk.Label(win, text=label).grid(row=i, column=0, sticky="w", padx=14, pady=10)
            ttk.Entry(win, textvariable=var, width=52).grid(row=i, column=1, sticky="ew", padx=14, pady=10)
        win.columnconfigure(1, weight=1)
        ttk.Label(
            win,
            text=(
                "Build 142 usa sqcli.exe. Mantén StrategyQuant X gráfico cerrado durante la conexión. "
                "El bridge puede controlar investigación y configuraciones, pero no tiene autoridad de broker/live."
            ),
            wraplength=560,
        ).grid(row=3, column=0, columnspan=2, padx=14, pady=8)

        def do_pair() -> None:
            try:
                if not Path(path.get().strip()).is_file():
                    raise RuntimeError("No encuentro sqcli.exe en esa ruta")
                if not code.get().strip():
                    raise RuntimeError("Falta el código de emparejamiento")
                data = ControlPlane.pair(code.get().strip(), device.get().strip() or socket.gethostname())
                if not data.get("ok"):
                    raise RuntimeError(data.get("error", "pair_failed"))
                new_cfg = BridgeConfig(
                    str(data["device_id"]),
                    str(data.get("device_name") or device.get()),
                    path.get().strip(),
                    False,
                    True,
                )
                new_cfg.save()
                keyring.set_password(KEYRING_SERVICE, new_cfg.device_id, str(data["bridge_token"]))
                self.cfg = new_cfg
                self.token = str(data["bridge_token"])
                self._load_cfg_to_ui()
                win.destroy()
                self.start_bridge()
            except Exception as exc:
                messagebox.showerror("No se pudo emparejar", str(exc), parent=win)

        ttk.Button(win, text="Emparejar y conectar", command=do_pair).grid(row=4, column=0, columnspan=2, pady=14)

    def test_sqx(self) -> None:
        path = self.cfg.sqcli_path if self.cfg else self.path_var.get()

        def work() -> None:
            try:
                probe_cfg = self.cfg or BridgeConfig("test", "test", path)
                runtime = SqCliRuntime(path)
                result = sqx_call(probe_cfg, runtime, "list_projects", {})
                excerpt = result.get("stdout", "")[:1000]
                self.events.put({"kind": "health", "text": "SQX CLI PASS\n" + excerpt, "tools": sorted(ALLOWLIST)})
            except Exception as exc:
                self.events.put({"kind": "error", "text": f"Prueba SQX: {exc}"})

        threading.Thread(target=work, daemon=True).start()

    def start_bridge(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        if not self.cfg or not self.token:
            self.open_setup()
            return
        self.worker = BridgeWorker(self.cfg, self.token, self.events)
        self.worker.start()
        self.status_var.set("Conectando…")
        self._log("Iniciando bridge")

    def stop_bridge(self) -> None:
        if self.worker:
            self.worker.stop()
        self.status_var.set("Detenido")

    def _save_control_flag(self) -> None:
        if self.cfg:
            self.cfg.allow_project_control = bool(self.control_var.get())
            self.cfg.save()
            self._log(
                "Control autónomo de investigación "
                + ("habilitado" if self.cfg.allow_project_control else "deshabilitado")
            )

    def _drain_events(self) -> None:
        while True:
            try:
                evt = self.events.get_nowait()
            except queue.Empty:
                break
            kind, text = evt.get("kind"), evt.get("text", "")
            self._log(text)
            if kind == "health":
                self.status_var.set("Conectado")
                self.tools_var.set(", ".join(evt.get("tools") or []))
            elif kind == "error":
                self.status_var.set("Reintentando")
            elif kind == "state" and "detenido" in text.lower():
                self.status_var.set("Detenido")
        self.after(250, self._drain_events)


if __name__ == "__main__":
    App().mainloop()
