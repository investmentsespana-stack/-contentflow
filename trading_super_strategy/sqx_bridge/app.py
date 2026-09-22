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
import urllib.parse
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
SQX_HTTP_API = "http://127.0.0.1:5050/call"
SQX_HTTP_TIMEOUT_SECONDS = 30.0
VIBE_ALLOWED_ASSETS = {"NQ", "ES", "CL", "GC", "DXY"}
VIBE_ASSET_ALIASES = {"DX": "DXY"}
VIBE_ASSET_ACTIONS = {"start", "status", "result"}
VIBE_SYNC_MAX_FILE_BYTES = 512 * 1024
VIBE_SYNC_ALLOWED_FILES = {
    "asset_research.py",
    "tradingview_futures_guard.py",
    "vibe_full_preflight.py",
    "cygnus_native_smoke.yaml",
    "cygnus_futures_strategy_lab.yaml",
    "cygnus_dxy_macro_lab.yaml",
}

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
    "vibe_diagnose",
    "stack_health",
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
    "freeze_databank",
    "live_project_control",
    "sync_vibe_runtime",
    "start_vibe",
    "stop_vibe",
    "restart_vibe",
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
    lowered = combined.lower()
    if "another instance of strategyquant x is running" in lowered:
        raise RuntimeError("SQCLI_SEMANTIC_FAILURE:another_instance_running")
    if cp.returncode != 0:
        hint = " Cierra StrategyQuant X gráfico antes de usar el bridge." if "another instance" in lowered else ""
        raise RuntimeError(f"SQCLI rc={cp.returncode}: {combined[:4000]}{hint}")
    return {"returncode": cp.returncode, "stdout": stdout, "stderr": stderr}


def _sqx_http_value(value: str, field: str, command: str) -> str:
    """Validate a value before embedding it into a fixed SQX HTTP CLI command."""
    return _safe_resource_name(value, field, command)


def _encode_sqx_http_cmd(command: str) -> str:
    """Encode only characters SQX's literal cmd= parser cannot receive raw.

    SQX Build 142 does not URL-decode '+' to space or '%3D' to '='. Keep
    command separators such as '=' and '-' literal, encode spaces as %20, and
    normalize Windows backslashes to forward slashes (accepted by SQX/Java).
    """
    return urllib.parse.quote(
        command.replace("\\", "/"),
        safe="=-/.,:_+()[]{}*\"'",
    )


def _sqx_http_call(command: str, timeout: float = SQX_HTTP_TIMEOUT_SECONDS) -> dict[str, Any]:
    """Call the loopback-only SQX Build 142 HTTP CLI endpoint.

    This is intentionally not exposed as arbitrary shell. Only fixed SQX
    command families are accepted, and the query value uses SQX's literal
    encoding rules instead of standard form encoding.
    """
    if not command.startswith(("-project ", "-databank ", "-h")):
        raise RuntimeError("SQX_HTTP_COMMAND_BLOCKED")
    encoded = _encode_sqx_http_cmd(command)
    url = f"{SQX_HTTP_API}?cmd={encoded}"
    try:
        with httpx.Client(timeout=timeout) as client:
            response = client.get(url)
            response.raise_for_status()
    except httpx.HTTPError as exc:
        raise RuntimeError(f"SQX_HTTP_UNAVAILABLE:{type(exc).__name__}:{exc}") from exc

    text = response.text.strip()
    if not text:
        raise RuntimeError("SQX_HTTP_EMPTY_RESPONSE")
    lowered = text.lower()
    if "parameter 'cmd' is missing" in lowered or 'parameter "cmd" is missing' in lowered:
        raise RuntimeError("SQX_HTTP_CMD_PARAMETER_REJECTED")
    if "unrecognized command" in lowered:
        raise RuntimeError("SQX_HTTP_COMMAND_UNRECOGNIZED:" + text[:500])
    return {
        "returncode": 0,
        "stdout": text,
        "stderr": "",
        "http_status": response.status_code,
        "http_api": SQX_HTTP_API,
    }


def _sqx_http_project_control(action: str, project: str) -> dict[str, Any]:
    """Control the already-running SQX GUI instance through its loopback HTTP API."""
    action = str(action or "").strip().lower()
    if action not in {"start", "stop", "pause", "resume"}:
        raise RuntimeError(f"SQX_HTTP_CONTROL_ACTION_BLOCKED:{action}")
    safe_project = _sqx_http_value(project, "project", f"http_{action}_project")
    result = _sqx_http_call(f"-project action={action} name='{safe_project}'")
    text = "\n".join(x for x in (result.get("stdout", ""), result.get("stderr", "")) if x)
    lowered = text.lower()
    failure_tokens = (
        "cannot start project",
        "cannot stop project",
        "cannot pause project",
        "cannot resume project",
        "unresolved resources",
        "failed",
        "error:",
    )
    if any(token in lowered for token in failure_tokens):
        raise RuntimeError(f"SQX_HTTP_CONTROL_FAILED:{action}:{text[:1200]}")
    result["control_action"] = action
    result["project"] = project
    return result


def _parse_sqx_status_metrics(text: str) -> dict[str, Any]:
    """Extract stable progress counters from SQX status output."""
    metrics: dict[str, Any] = {}
    patterns: tuple[tuple[str, str, type], ...] = (
        ("strategies_generated", r"Strategies generated\s+([0-9]+)", int),
        ("rejected_pct", r"Rejected\s+([0-9.]+)\s*%", float),
        ("accepted_pct", r"Accepted\s+([0-9.]+)\s*%", float),
        ("failed", r"Failed\s+([0-9]+)", int),
        ("passed", r"Passed\s+([0-9]+)", int),
        ("strategies_per_hour", r"Strategies per hour\s+([0-9.]+)", float),
        ("accepted_strategies_per_hour", r"Accepted strategies per hour\s+([0-9.]+)", float),
        ("in_databank", r"In databank\s+([0-9]+)", int),
    )
    for key, pattern, caster in patterns:
        match = re.search(pattern, text or "", flags=re.IGNORECASE)
        if match:
            try:
                metrics[key] = caster(match.group(1))
            except (TypeError, ValueError):
                pass
    running_match = re.search(r"Running time so far\s+(.+)", text or "", flags=re.IGNORECASE)
    if running_match:
        metrics["running_time"] = running_match.group(1).strip()
    record_match = re.search(r"Records:\s*([0-9]+)", text or "", flags=re.IGNORECASE)
    if record_match:
        metrics["records"] = int(record_match.group(1))
    return metrics



def _sqx_project_root(cfg: BridgeConfig, project: str) -> Path:
    safe_project = _safe_resource_name(project, "project", "project_telemetry")
    sqx_root = Path(cfg.sqcli_path).resolve().parent
    projects_root = (sqx_root / "user" / "projects").resolve()
    project_root = (projects_root / safe_project).resolve()
    if projects_root != project_root and projects_root not in project_root.parents:
        raise RuntimeError("SQX_PROJECT_PATH_BLOCKED")
    if not project_root.is_dir():
        raise RuntimeError(f"SQX_PROJECT_DIR_MISSING:{project_root}")
    return project_root


def _read_text_tail(path: Path, max_bytes: int = 512 * 1024) -> str:
    with path.open("rb") as fh:
        size = path.stat().st_size
        if size > max_bytes:
            fh.seek(size - max_bytes)
        data = fh.read()
    return _decode(data)


def _latest_project_log(cfg: BridgeConfig, project: str) -> dict[str, Any]:
    project_root = _sqx_project_root(cfg, project)
    log_dir = project_root / "log"
    if not log_dir.is_dir():
        raise RuntimeError(f"SQX_PROJECT_LOG_DIR_MISSING:{log_dir}")
    logs = [p for p in log_dir.glob("global_log_*.log") if p.is_file()]
    if not logs:
        logs = [p for p in log_dir.glob("*.log") if p.is_file()]
    if not logs:
        raise RuntimeError(f"SQX_PROJECT_LOG_MISSING:{log_dir}")
    latest = max(logs, key=lambda p: p.stat().st_mtime)
    text = _read_text_tail(latest)
    mtime = latest.stat().st_mtime
    age = max(0.0, time.time() - mtime)

    start_pos = max(
        text.lower().rfind("=========== project started ===========".lower()),
        text.lower().rfind("starting project"),
    )
    terminal_markers = (
        "project stopped",
        "project finished",
        "project aborted",
        "stopping project",
        "exit app",
    )
    terminal_pos = max([text.lower().rfind(x) for x in terminal_markers] + [-1])
    unclosed_start = start_pos >= 0 and terminal_pos < start_pos

    return {
        "project_root": str(project_root),
        "log_path": str(latest),
        "log_size": latest.stat().st_size,
        "log_mtime_epoch": mtime,
        "log_age_seconds": round(age, 1),
        "unclosed_start_marker": unclosed_start,
        "status_metrics": _parse_sqx_status_metrics(text),
        "log_tail": text[-12000:],
    }


def _sqx_instance_alive() -> tuple[bool, str]:
    try:
        probe = _sqx_http_call("-h", timeout=5.0)
        return True, probe.get("stdout", "")[:1000]
    except Exception as exc:
        return False, str(exc)[:1000]


def _databank_file_count(cfg: BridgeConfig, project: str, databank: str) -> dict[str, Any]:
    project_root = _sqx_project_root(cfg, project)
    safe_databank = _safe_resource_name(databank, "databank", "count_databank")

    direct = [
        project_root / "databanks" / safe_databank,
        project_root / "databank" / safe_databank,
        project_root / "data" / "databanks" / safe_databank,
        project_root / safe_databank,
    ]
    candidates: list[Path] = []
    for p in direct:
        if p.is_dir():
            candidates.append(p.resolve())

    if not candidates:
        # Constrained discovery: only directories already below this validated project.
        target = safe_databank.casefold()
        for p in project_root.rglob("*"):
            if p.is_dir() and p.name.casefold() == target:
                rp = p.resolve()
                if project_root == rp or project_root in rp.parents:
                    candidates.append(rp)

    best: tuple[int, Path, list[Path]] | None = None
    for p in candidates:
        strategy_files = [x for x in p.rglob("*.sqx") if x.is_file()]
        score = len(strategy_files)
        if best is None or score > best[0]:
            best = (score, p, strategy_files)

    if best is None:
        raise RuntimeError(
            f"SQX_DATABANK_DIR_NOT_FOUND:project={project};databank={databank}"
        )

    count, path, files = best
    latest_mtime = max((x.stat().st_mtime for x in files), default=path.stat().st_mtime)
    return {
        "records": count,
        "databank_path": str(path),
        "strategy_extension": ".sqx",
        "latest_strategy_mtime_epoch": latest_mtime,
        "latest_strategy_age_seconds": round(max(0.0, time.time() - latest_mtime), 1),
        "sample_files": [x.name for x in sorted(files, key=lambda x: x.name)[:5]],
    }


def _freeze_databank_snapshot(cfg: BridgeConfig, project: str, databank: str, label: str | None = None) -> dict[str, Any]:
    """Create an immutable file snapshot of a StrategyQuant databank with SHA-256 manifest."""
    info = _databank_file_count(cfg, project, databank)
    source = Path(info["databank_path"]).resolve()
    project_root = _sqx_project_root(cfg, project)
    if project_root != source and project_root not in source.parents:
        raise RuntimeError("SQX_FREEZE_SOURCE_OUTSIDE_PROJECT")

    safe_label = _safe_slug(label or time.strftime("%Y%m%d-%H%M%S"), "snapshot")
    snapshot_root = ARTIFACT_DIR / "frozen_databanks" / _safe_slug(project) / _safe_slug(databank) / safe_label
    if snapshot_root.exists():
        raise RuntimeError(f"SQX_FREEZE_ALREADY_EXISTS:{snapshot_root}")
    snapshot_root.mkdir(parents=True, exist_ok=False)

    entries: list[dict[str, Any]] = []
    try:
        files = sorted([p for p in source.rglob("*.sqx") if p.is_file()], key=lambda p: str(p.relative_to(source)).casefold())
        for src in files:
            rel = src.relative_to(source)
            before = src.read_bytes()
            before_sha = hashlib.sha256(before).hexdigest()
            dest = snapshot_root / rel
            dest.parent.mkdir(parents=True, exist_ok=True)
            dest.write_bytes(before)
            copied_sha = hashlib.sha256(dest.read_bytes()).hexdigest()
            after_sha = hashlib.sha256(src.read_bytes()).hexdigest()
            if not (before_sha == copied_sha == after_sha):
                raise RuntimeError(f"SQX_FREEZE_MUTATION_DETECTED:{rel}")
            entries.append({
                "file": str(rel).replace("\\", "/"),
                "size": len(before),
                "sha256": before_sha,
            })
        after_info = _databank_file_count(cfg, project, databank)
        if int(after_info.get("records", -1)) != int(info.get("records", -2)):
            raise RuntimeError(
                f"SQX_FREEZE_DATABANK_CHANGED:before={info.get('records')}:after={after_info.get('records')}"
            )

        manifest = {
            "project": project,
            "databank": databank,
            "label": safe_label,
            "created_at_epoch": time.time(),
            "strategy_count": len(entries),
            "source_records_before": info.get("records"),
            "source_records_after": after_info.get("records"),
            "source_path": str(source),
            "snapshot_path": str(snapshot_root),
            "files": entries,
        }
        manifest_bytes = json.dumps(manifest, indent=2, sort_keys=True).encode("utf-8")
        manifest_path = snapshot_root / "manifest.json"
        manifest_path.write_bytes(manifest_bytes)
        return {
            "returncode": 0,
            "stdout": f"Frozen {len(entries)} strategies from {project}/{databank}",
            "stderr": "",
            "snapshot_path": str(snapshot_root),
            "manifest_path": str(manifest_path),
            "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
            "strategy_count": len(entries),
        }
    except Exception:
        for p in sorted(snapshot_root.rglob("*"), reverse=True):
            try:
                if p.is_file():
                    p.unlink()
                elif p.is_dir():
                    p.rmdir()
            except Exception:
                pass
        try:
            snapshot_root.rmdir()
        except Exception:
            pass
        raise


def _project_file_status(cfg: BridgeConfig, project: str) -> dict[str, Any]:
    log = _latest_project_log(cfg, project)
    instance_alive, probe_excerpt = _sqx_instance_alive()
    inferred_running = bool(instance_alive and log.get("unclosed_start_marker"))
    return {
        **log,
        "instance_http_alive": instance_alive,
        "http_probe_excerpt": probe_excerpt,
        "running_inferred": inferred_running,
        "telemetry_source": "sqx_project_files+http_liveness",
    }


def _read_only_http_or_sqcli(
    cfg: BridgeConfig,
    runtime: "SqCliRuntime",
    *,
    command_name: str,
    http_command: str,
    sqcli_args: list[str],
    timeout: int = 180,
) -> tuple[dict[str, Any], dict[str, Any]]:
    """Prefer the already-running SQX HTTP API; never start a second SQX for telemetry."""
    try:
        result = _sqx_http_call(http_command)
        return result, {
            "transport": "sqx_http_api",
            "attached_existing_instance": True,
            "status_metrics": _parse_sqx_status_metrics(result.get("stdout", "")),
        }
    except RuntimeError as http_exc:
        if runtime.is_running():
            raise RuntimeError(f"SQX_LIVE_TELEMETRY_UNAVAILABLE:{http_exc}") from http_exc
        live_instance, _ = _sqx_instance_alive()
        if live_instance:
            raise RuntimeError(
                f"SQX_EXISTING_INSTANCE_DETECTED_NO_COMPETING_CLI:{http_exc}"
            ) from http_exc
        result = _run_sqcli(cfg.sqcli_path, sqcli_args, timeout=timeout)
        combined = "\n".join(
            x for x in (result.get("stdout", ""), result.get("stderr", "")) if x
        )
        if "another instance of strategyquant x is running" in combined.lower():
            raise RuntimeError(
                "SQX_EXISTING_INSTANCE_DETECTED_BUT_HTTP_TELEMETRY_UNAVAILABLE:"
                + str(http_exc)
            ) from http_exc
        return result, {
            "transport": "sqcli_process",
            "attached_existing_instance": False,
            "status_metrics": _parse_sqx_status_metrics(combined),
        }


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



def _vibe_preset_destinations(name: str) -> list[Path]:
    if name not in {"cygnus_native_smoke.yaml", "cygnus_futures_strategy_lab.yaml", "cygnus_dxy_macro_lab.yaml"}:
        return []
    return [
        Path.home() / ".vibe-trading" / "swarm" / "presets" / name,
        VIBE_ROOT / "state" / "swarm" / "presets" / name,
    ]


def _vibe_runtime_destinations(name: str) -> list[Path]:
    if name in {"asset_research.py", "tradingview_futures_guard.py", "vibe_full_preflight.py"}:
        return [VIBE_ROOT / name]
    return _vibe_preset_destinations(name)


def _sync_vibe_runtime(payload: dict[str, Any]) -> dict[str, Any]:
    files = payload.get("files")
    if not isinstance(files, list) or not files:
        raise RuntimeError("sync_vibe_runtime requiere payload.files no vacío")
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    backup_root = ARTIFACT_DIR / "vibe_backups" / stamp
    backup_root.mkdir(parents=True, exist_ok=False)
    written: list[dict[str, Any]] = []
    backups: list[tuple[Path, Path | None]] = []
    try:
        for item in files:
            if not isinstance(item, dict):
                raise RuntimeError("sync_vibe_runtime: item inválido")
            name = str(item.get("name") or "").strip()
            if name not in VIBE_SYNC_ALLOWED_FILES:
                raise RuntimeError(f"VIBE_SYNC_FILE_BLOCKED:{name}")
            encoded = str(item.get("content_b64") or "")
            expected_sha = str(item.get("sha256") or "").lower().strip()
            if not re.fullmatch(r"[0-9a-f]{64}", expected_sha):
                raise RuntimeError(f"VIBE_SYNC_SHA256_INVALID:{name}")
            try:
                data = base64.b64decode(encoded, validate=True)
            except Exception as exc:
                raise RuntimeError(f"VIBE_SYNC_BASE64_INVALID:{name}:{exc}") from exc
            if not data or len(data) > VIBE_SYNC_MAX_FILE_BYTES:
                raise RuntimeError(f"VIBE_SYNC_SIZE_INVALID:{name}:{len(data)}")
            actual_sha = hashlib.sha256(data).hexdigest()
            if actual_sha != expected_sha:
                raise RuntimeError(f"VIBE_SYNC_HASH_MISMATCH:{name}")

            destinations = _vibe_runtime_destinations(name)
            if not destinations:
                raise RuntimeError(f"VIBE_SYNC_DESTINATION_MISSING:{name}")
            for dest in destinations:
                dest.parent.mkdir(parents=True, exist_ok=True)
                backup: Path | None = None
                if dest.exists():
                    backup = backup_root / _safe_slug(str(dest).replace(":", "_"))
                    backup.parent.mkdir(parents=True, exist_ok=True)
                    backup.write_bytes(dest.read_bytes())
                temp = dest.with_name(dest.name + ".cygnus_tmp")
                temp.write_bytes(data)
                if hashlib.sha256(temp.read_bytes()).hexdigest() != expected_sha:
                    raise RuntimeError(f"VIBE_SYNC_TEMP_VERIFY_FAILED:{name}")
                os.replace(temp, dest)
                if hashlib.sha256(dest.read_bytes()).hexdigest() != expected_sha:
                    raise RuntimeError(f"VIBE_SYNC_DEST_VERIFY_FAILED:{name}")
                backups.append((dest, backup))
                written.append({"name": name, "destination": str(dest), "sha256": expected_sha, "size": len(data)})

        py_files = [str(VIBE_ROOT / n) for n in ("tradingview_futures_guard.py", "asset_research.py", "vibe_full_preflight.py") if (VIBE_ROOT / n).is_file()]
        if py_files:
            cp = subprocess.run(
                [str(VIBE_PYTHON), "-m", "py_compile", *py_files],
                cwd=str(VIBE_ROOT),
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=120,
                shell=False,
            )
            if cp.returncode != 0:
                raise RuntimeError("VIBE_SYNC_PY_COMPILE_FAILED:" + _decode(cp.stderr)[:1600])

        manifest = {
            "schema": "cygnus.vibe.runtime_sync.v1",
            "synced_at_utc": stamp,
            "files": written,
            "restart_required": False,
            "reason": "asset runner is launched fresh per request; presets are read from disk for new runs",
        }
        manifest_bytes = json.dumps(manifest, indent=2, ensure_ascii=False).encode("utf-8")
        manifest_path = backup_root / "sync_manifest.json"
        manifest_path.write_bytes(manifest_bytes)
        return {
            "returncode": 0,
            "stdout": f"VIBE_RUNTIME_SYNC=PASS files={len(written)}",
            "stderr": "",
            "synced": written,
            "backup_root": str(backup_root),
            "manifest_path": str(manifest_path),
            "manifest_sha256": hashlib.sha256(manifest_bytes).hexdigest(),
        }
    except Exception:
        for dest, backup in reversed(backups):
            try:
                if backup and backup.exists():
                    temp = dest.with_name(dest.name + ".rollback_tmp")
                    temp.write_bytes(backup.read_bytes())
                    os.replace(temp, dest)
                elif dest.exists():
                    dest.unlink()
            except Exception:
                pass
        raise


def _vibe_service_control(action: str) -> dict[str, Any]:
    action = str(action or "").strip().lower()
    if action not in {"start", "stop", "restart"}:
        raise RuntimeError(f"VIBE_SERVICE_ACTION_BLOCKED:{action}")
    scripts = {
        "start": VIBE_ROOT / "Start-VibeNative.ps1",
        "stop": VIBE_ROOT / "Stop-VibeNative.ps1",
    }
    for p in scripts.values():
        if not p.is_file():
            raise RuntimeError(f"VIBE_SERVICE_SCRIPT_MISSING:{p}")
    outputs: list[str] = []
    actions = ["stop", "start"] if action == "restart" else [action]
    for step in actions:
        cp = subprocess.run(
            ["powershell.exe", "-NoLogo", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(scripts[step])],
            cwd=str(VIBE_ROOT),
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=180,
            shell=False,
        )
        text_out = "\n".join(x for x in (_decode(cp.stdout).strip(), _decode(cp.stderr).strip()) if x)
        outputs.append(f"[{step}] {text_out}")
        if cp.returncode != 0:
            raise RuntimeError(f"VIBE_SERVICE_{step.upper()}_FAILED:{text_out[:1800]}")
        if step == "stop" and action == "restart":
            time.sleep(2)
    return {
        "returncode": 0,
        "stdout": "\n".join(outputs),
        "stderr": "",
        "service_action": action,
    }


def _latest_vibe_health_evidence() -> Path | None:
    if not (VIBE_ROOT / "evidence").is_dir():
        return None
    candidates = sorted(
        [p for p in (VIBE_ROOT / "evidence").glob("vibe-full-health*.json") if p.is_file()],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )
    return candidates[0] if candidates else None


def _vibe_diagnose() -> dict[str, Any]:
    script = VIBE_ROOT / "vibe_full_preflight.py"
    if not VIBE_PYTHON.is_file():
        raise RuntimeError(f"VIBE_PYTHON_MISSING:{VIBE_PYTHON}")
    if not script.is_file():
        raise RuntimeError(f"VIBE_PREFLIGHT_MISSING:{script}")
    cp = subprocess.run(
        [str(VIBE_PYTHON), str(script)],
        cwd=str(VIBE_ROOT),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=240,
        shell=False,
    )
    evidence_path = _latest_vibe_health_evidence()
    evidence: dict[str, Any] = {}
    if evidence_path and evidence_path.is_file():
        try:
            evidence = json.loads(evidence_path.read_text(encoding="utf-8"))
        except Exception as exc:
            evidence = {"status": "UNREADABLE", "error": str(exc)}
    checks = evidence.get("checks") if isinstance(evidence, dict) else {}
    failed_checks = []
    if isinstance(checks, dict):
        failed_checks = [name for name, value in checks.items() if not (isinstance(value, dict) and value.get("ok") is True)]
    return {
        "returncode": 0,
        "stdout": _decode(cp.stdout).strip(),
        "stderr": _decode(cp.stderr).strip(),
        "preflight_rc": cp.returncode,
        "diagnostic_complete": True,
        "status": evidence.get("status") if isinstance(evidence, dict) else None,
        "failed_checks": failed_checks,
        "evidence_path": str(evidence_path) if evidence_path else None,
        "evidence": evidence,
    }


def _stack_health(cfg: BridgeConfig) -> dict[str, Any]:
    sqx_alive, sqx_probe = _sqx_instance_alive()
    vibe_python = VIBE_PYTHON.is_file()
    asset_runner = VIBE_ASSET_SCRIPT.is_file()
    guard = VIBE_ROOT / "tradingview_futures_guard.py"
    guard_present = guard.is_file()
    mcp_ready = False
    mcp_error = None
    try:
        with socket.create_connection(("127.0.0.1", 8900), timeout=2):
            mcp_ready = True
    except Exception as exc:
        mcp_error = f"{type(exc).__name__}:{exc}"
    evidence_path = _latest_vibe_health_evidence()
    latest_health = None
    if evidence_path:
        try:
            latest_health = json.loads(evidence_path.read_text(encoding="utf-8")).get("status")
        except Exception:
            latest_health = "UNREADABLE"
    return {
        "returncode": 0,
        "stdout": "STACK_HEALTH_CHECKED",
        "stderr": "",
        "bridge_version": "142-autonomy-v6.4.1-stack-control",
        "strategyquant": {"http_alive": sqx_alive, "probe_excerpt": sqx_probe[:800]},
        "vibe": {
            "python_present": vibe_python,
            "asset_runner_present": asset_runner,
            "mcp_8900_ready": mcp_ready,
            "mcp_error": mcp_error,
            "latest_health_status": latest_health,
            "latest_health_evidence": str(evidence_path) if evidence_path else None,
        },
        "tradingview_guard": {"present": guard_present},
        "research_only": True,
        "broker_execution": False,
        "arbitrary_shell": False,
    }


def _run_vibe_asset_research(payload: dict[str, Any]) -> dict[str, Any]:
    """Run fixed, allowlisted multi-asset Vibe research. No arbitrary prompt or shell input."""
    action = str(payload.get("action") or "start").strip().lower()
    if action not in VIBE_ASSET_ACTIONS:
        raise RuntimeError(f"VIBE_ACTION_NOT_ALLOWED:{action}")

    asset = ""
    run_id = ""
    if action == "start":
        asset = str(payload.get("asset") or "").strip().upper()
        asset = VIBE_ASSET_ALIASES.get(asset, asset)
        if asset not in VIBE_ALLOWED_ASSETS:
            raise RuntimeError(f"ASSET_NOT_ALLOWED:{asset}")
    else:
        run_id = str(payload.get("run_id") or "").strip()
        if not re.fullmatch(r"[A-Za-z0-9._:-]{1,160}", run_id):
            raise RuntimeError("INVALID_RUN_ID")

    python_exe = VIBE_PYTHON.resolve()
    script = VIBE_ASSET_SCRIPT.resolve()
    root = VIBE_ROOT.resolve()
    if not python_exe.is_file():
        raise RuntimeError(f"VIBE_PYTHON_MISSING:{python_exe}")
    if not script.is_file():
        raise RuntimeError(f"VIBE_ASSET_SCRIPT_MISSING:{script}")
    if root not in python_exe.parents or root not in script.parents:
        raise RuntimeError("VIBE_FIXED_PATH_POLICY_FAIL")

    args = [str(python_exe), str(script), "--action", action, "--mcp-url", VIBE_MCP_URL]
    if action == "start":
        args.extend(["--asset", asset])
    else:
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
            extra["status_metrics"] = _parse_sqx_status_metrics(result["stdout"])
            extra["telemetry_source"] = "bridge_owned_process"
        else:
            safe_project = _sqx_http_value(project, "project", name)
            live_instance, _ = _sqx_instance_alive()
            if live_instance:
                result = _sqx_http_call(f"-project action=status name='{safe_project}'")
                extra["transport"] = "sqx_http_api"
                extra["attached_existing_instance"] = True
                extra["status_metrics"] = _parse_sqx_status_metrics(result.get("stdout", ""))
                extra["telemetry_source"] = "sqx_http_api"
                try:
                    extra["file_evidence"] = _project_file_status(cfg, project)
                except Exception as file_exc:
                    extra["project_file_telemetry_error"] = str(file_exc)
            else:
                try:
                    file_status = _project_file_status(cfg, project)
                    state = "RUNNING" if file_status.get("running_inferred") else "STATE_UNCERTAIN"
                    result = {
                        "returncode": 0,
                        "stdout": (
                            f"Project {project} {state} via read-only project telemetry\n"
                            + file_status.get("log_tail", "")
                        ),
                        "stderr": "",
                    }
                    extra["runtime"] = file_status
                    extra["status_metrics"] = file_status.get("status_metrics", {})
                    extra["transport"] = "sqx_project_files"
                    extra["attached_existing_instance"] = False
                except RuntimeError as file_exc:
                    result, telemetry = _read_only_http_or_sqcli(
                        cfg,
                        runtime,
                        command_name=name,
                        http_command=f"-project action=status name='{safe_project}'",
                        sqcli_args=["-project", "action=status", f"name={project}"],
                        timeout=180,
                    )
                    extra.update(telemetry)
                    extra["project_file_telemetry_error"] = str(file_exc)

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
        project = _project_from_payload(name, payload)
        databank = _databank_from_payload(name, payload)
        try:
            file_count = _databank_file_count(cfg, project, databank)
            result = {
                "returncode": 0,
                "stdout": f"Records: {file_count['records']}",
                "stderr": "",
            }
            extra.update(file_count)
            extra["status_metrics"] = {"records": file_count["records"]}
            extra["transport"] = "sqx_project_files"
            extra["attached_existing_instance"] = _sqx_instance_alive()[0]
        except RuntimeError as file_exc:
            safe_project = _sqx_http_value(project, "project", name)
            safe_databank = _sqx_http_value(databank, "databank", name)
            result, telemetry = _read_only_http_or_sqcli(
                cfg,
                runtime,
                command_name=name,
                http_command=f'-databank action=count project="{safe_project}" name="{safe_databank}"',
                sqcli_args=["-databank", "action=count", f"project={project}", f"name={databank}"],
                timeout=180,
            )
            extra.update(telemetry)
            extra["project_file_telemetry_error"] = str(file_exc)

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

    elif name == "vibe_diagnose":
        if payload:
            raise RuntimeError("vibe_diagnose no acepta payload")
        result = _vibe_diagnose()
        extra["transport"] = "fixed_vibe_preflight"

    elif name == "stack_health":
        if payload:
            raise RuntimeError("stack_health no acepta payload")
        result = _stack_health(cfg)
        extra["transport"] = "local_stack_probe"

    elif name == "sync_vibe_runtime":
        result = _sync_vibe_runtime(payload)
        extra["transport"] = "atomic_vibe_runtime_sync"

    elif name in {"start_vibe", "stop_vibe", "restart_vibe"}:
        action = {"start_vibe": "start", "stop_vibe": "stop", "restart_vibe": "restart"}[name]
        result = _vibe_service_control(action)
        extra["transport"] = "fixed_vibe_service_control"

    elif name == "live_project_control":
        project = _project_from_payload(name, payload)
        action = str(payload.get("action") or "").strip().lower()
        if action not in {"start", "stop", "pause", "resume"}:
            raise RuntimeError("live_project_control requiere action=start|stop|pause|resume")
        active = runtime.status(project)
        live_instance, _ = _sqx_instance_alive()
        if action == "stop" and active and active.get("running"):
            result = runtime.stop_project(project)
        elif live_instance:
            result = _sqx_http_project_control(action, project)
            extra.update({"transport": "sqx_http_api", "attached_existing_instance": True})
        elif action == "start":
            result = runtime.start_project(project)
        elif action == "stop":
            result = runtime.stop_project(project)
        else:
            result = _run_sqcli(cfg.sqcli_path, ["-project", f"action={action}", f"name={project}"], timeout=180)

    elif name == "run_project":
        project = _project_from_payload(name, payload)
        live_instance, _ = _sqx_instance_alive()
        if live_instance:
            result = _sqx_http_project_control("start", project)
            extra.update({"transport": "sqx_http_api", "attached_existing_instance": True})
        else:
            result = runtime.start_project(project)

    elif name == "stop_project":
        project = _project_from_payload(name, payload)
        active = runtime.status(project)
        if active and active.get("running"):
            result = runtime.stop_project(project)
        else:
            live_instance, _ = _sqx_instance_alive()
            if live_instance:
                result = _sqx_http_project_control("stop", project)
                extra.update({"transport": "sqx_http_api", "attached_existing_instance": True})
            else:
                result = runtime.stop_project(project)

    elif name in {"pause_project", "resume_project"}:
        project = _project_from_payload(name, payload)
        action = "pause" if name == "pause_project" else "resume"
        live_instance, _ = _sqx_instance_alive()
        if live_instance:
            result = _sqx_http_project_control(action, project)
            extra.update({"transport": "sqx_http_api", "attached_existing_instance": True})
        else:
            result = _run_sqcli(cfg.sqcli_path, ["-project", f"action={action}", f"name={project}"], timeout=180)

    elif name == "freeze_databank":
        project = _project_from_payload(name, payload)
        databank = _databank_from_payload(name, payload)
        label = str(payload.get("label") or "").strip() or None
        result = _freeze_databank_snapshot(cfg, project, databank, label)
        extra.update({
            "transport": "sqx_project_files",
            "attached_existing_instance": _sqx_instance_alive()[0],
        })

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
            # After a Bridge restart the running SQX process is no longer owned
            # by this Python runtime. Prefer Build 142's loopback HTTP API so a
            # heartbeat never attempts to launch a competing sqcli.exe.
            if not self.last_probe or time.monotonic() - self.last_probe >= 300:
                self.last_probe = 0.0
                self.cached_probe_excerpt = ""
                try:
                    probe = _sqx_http_call("-h", timeout=5.0)
                    self.cached_probe_excerpt = (
                        "attached_existing_instance=true transport=sqx_http_api\n"
                        + probe.get("stdout", "")[:1100]
                    )
                except Exception as http_exc:
                    try:
                        probe = sqx_call(self.cfg, self.runtime, "list_projects", {})
                        self.cached_probe_excerpt = probe.get("stdout", "")[:1200]
                    except Exception as cli_exc:
                        self.cached_probe_excerpt = (
                            f"SQX probe unavailable: http={http_exc}; cli={cli_exc}"
                        )[:1200]
                self.last_probe = time.monotonic()
            sqx_ok = not self.cached_probe_excerpt.startswith("SQX probe unavailable:")
            probe_excerpt = self.cached_probe_excerpt
        health = {
            "hostname": socket.gethostname(),
            "transport": "sqcli_process",
            "bridge_version": "142-autonomy-v6.4.1-stack-control",
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
        ttk.Label(top, text="Cygnus SQX Bridge · Build 142 · Stack Control v6.4", font=("Segoe UI", 15, "bold")).pack(side="left")
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
