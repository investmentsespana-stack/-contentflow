from __future__ import annotations

import json
import os
import queue
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
ALLOWLIST = {"list_projects", "list_databanks", "run_project", "stop_project"}
READ_ONLY = {"list_projects", "list_databanks"}


def config_dir() -> Path:
    base = Path(os.environ.get("APPDATA") or Path.home())
    p = base / "CygnusSQXBridge"
    p.mkdir(parents=True, exist_ok=True)
    return p


CONFIG_PATH = config_dir() / "config.json"


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
        return cls(**raw)

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


def run_sqcli(path: str, args: list[str], timeout: int = 180) -> dict[str, Any]:
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


def sqx_call(cfg: BridgeConfig, name: str, payload: dict[str, Any]) -> dict[str, Any]:
    if name not in ALLOWLIST:
        raise RuntimeError(f"Comando bloqueado por allowlist: {name}")
    if name == "list_projects":
        result = run_sqcli(cfg.sqcli_path, ["-project", "action=list"])
    elif name == "list_databanks":
        project = str(payload.get("project") or "").strip()
        if not project:
            raise RuntimeError("list_databanks requiere payload.project")
        result = run_sqcli(cfg.sqcli_path, ["-databank", "action=list", f"project={project}"])
    elif name in {"run_project", "stop_project"}:
        if not cfg.allow_project_control:
            raise RuntimeError("Control start/stop está deshabilitado localmente")
        project = str(payload.get("project") or payload.get("name") or "").strip()
        if not project:
            raise RuntimeError(f"{name} requiere payload.project")
        action = "start" if name == "run_project" else "stop"
        result = run_sqcli(cfg.sqcli_path, ["-project", f"action={action}", f"name={project}"], timeout=3600)
    else:
        raise RuntimeError(f"Comando no implementado: {name}")
    return {"transport": "sqcli_process", "sqcli_path": cfg.sqcli_path, "command": name, **result}


class BridgeWorker(threading.Thread):
    def __init__(self, cfg: BridgeConfig, token: str, events: queue.Queue):
        super().__init__(daemon=True)
        self.cfg = cfg
        self.events = events
        self.stop_event = threading.Event()
        self.control = ControlPlane(token)
        self.last_heartbeat = 0.0

    def emit(self, kind: str, text: str, **extra: Any) -> None:
        self.events.put({"kind": kind, "text": text, **extra})

    def stop(self) -> None:
        self.stop_event.set()

    def run(self) -> None:
        self.emit("state", "Bridge iniciado")
        while not self.stop_event.is_set():
            try:
                if time.time() - self.last_heartbeat > 120:
                    probe = sqx_call(self.cfg, "list_projects", {})
                    health = {
                        "hostname": socket.gethostname(),
                        "transport": "sqcli_process",
                        "sqcli_path": self.cfg.sqcli_path,
                        "sqx_cli_ok": True,
                        "capabilities": sorted(ALLOWLIST),
                        "project_control_enabled": self.cfg.allow_project_control,
                        "probe_excerpt": probe.get("stdout", "")[:1200],
                    }
                    self.control.post({"action": "heartbeat", "health": health})
                    self.last_heartbeat = time.time()
                    self.emit("health", "SQX CLI conectado", tools=sorted(ALLOWLIST))

                claimed = self.control.post({"action": "claim"})
                command = claimed.get("command")
                if not command:
                    time.sleep(3)
                    continue
                ctype = str(command.get("command_type", ""))
                payload = command.get("payload") or {}
                cid = command.get("id")
                nonce = command.get("claim_nonce")
                self.emit("command", f"Ejecutando {ctype}", command_id=cid)
                try:
                    result = sqx_call(self.cfg, ctype, payload)
                    self.control.post({"action": "complete", "command_id": cid, "claim_nonce": nonce, "success": True, "result": result})
                    self.emit("command", f"Completado {ctype}", command_id=cid)
                except Exception as exc:
                    self.control.post({"action": "complete", "command_id": cid, "claim_nonce": nonce, "success": False, "error": str(exc)})
                    self.emit("error", f"{ctype}: {exc}", command_id=cid)
            except Exception as exc:
                self.emit("error", str(exc))
                time.sleep(8)
        self.emit("state", "Bridge detenido")


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_NAME)
        self.geometry("700x470")
        self.minsize(640, 420)
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
        top = ttk.Frame(self); top.pack(fill="x", **pad)
        ttk.Label(top, text="Cygnus SQX Bridge · Build 142 CLI", font=("Segoe UI", 15, "bold")).pack(side="left")
        self.status_var = tk.StringVar(value="No conectado")
        ttk.Label(top, textvariable=self.status_var).pack(side="right")
        info = ttk.LabelFrame(self, text="Conexión"); info.pack(fill="x", **pad)
        self.device_var = tk.StringVar(value="—")
        self.path_var = tk.StringVar(value=DEFAULT_SQCLI_PATH)
        self.tools_var = tk.StringVar(value="—")
        for i, (label, var) in enumerate((("Dispositivo", self.device_var), ("SQCLI", self.path_var), ("Capacidades", self.tools_var))):
            ttk.Label(info, text=label, width=14).grid(row=i, column=0, sticky="w", padx=8, pady=4)
            ttk.Label(info, textvariable=var).grid(row=i, column=1, sticky="w", padx=8, pady=4)
        buttons = ttk.Frame(self); buttons.pack(fill="x", **pad)
        ttk.Button(buttons, text="Configurar / Emparejar", command=self.open_setup).pack(side="left", padx=4)
        ttk.Button(buttons, text="Probar SQX", command=self.test_sqx).pack(side="left", padx=4)
        ttk.Button(buttons, text="Iniciar", command=self.start_bridge).pack(side="left", padx=4)
        ttk.Button(buttons, text="Detener", command=self.stop_bridge).pack(side="left", padx=4)
        self.control_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(self, text="Permitir iniciar/detener proyectos de investigación", variable=self.control_var, command=self._save_control_flag).pack(anchor="w", padx=18, pady=4)
        logframe = ttk.LabelFrame(self, text="Actividad"); logframe.pack(fill="both", expand=True, **pad)
        self.log = tk.Text(logframe, height=13, wrap="word", state="disabled"); self.log.pack(fill="both", expand=True, padx=6, pady=6)

    def _log(self, text: str) -> None:
        self.log.configure(state="normal")
        self.log.insert("end", f"[{time.strftime('%H:%M:%S')}] {text}\n")
        self.log.see("end"); self.log.configure(state="disabled")

    def _load_cfg_to_ui(self) -> None:
        if not self.cfg: return
        self.device_var.set(f"{self.cfg.device_name} · {self.cfg.device_id[:8]}")
        self.path_var.set(self.cfg.sqcli_path)
        self.control_var.set(self.cfg.allow_project_control)
        self.tools_var.set(", ".join(sorted(ALLOWLIST)))

    def open_setup(self) -> None:
        win = tk.Toplevel(self); win.title("Configurar SQX Bridge"); win.geometry("600x300"); win.grab_set()
        device = tk.StringVar(value=self.cfg.device_name if self.cfg else socket.gethostname())
        path = tk.StringVar(value=self.cfg.sqcli_path if self.cfg else DEFAULT_SQCLI_PATH)
        code = tk.StringVar(value="")
        for i, (label, var) in enumerate((("Nombre del PC", device), ("Ruta sqcli.exe", path), ("Código de emparejamiento", code))):
            ttk.Label(win, text=label).grid(row=i, column=0, sticky="w", padx=14, pady=10)
            ttk.Entry(win, textvariable=var, width=52).grid(row=i, column=1, sticky="ew", padx=14, pady=10)
        win.columnconfigure(1, weight=1)
        ttk.Label(win, text="Build 142 usa sqcli.exe. Mantén StrategyQuant X gráfico cerrado durante la conexión. El token queda en Windows Credential Manager.", wraplength=540).grid(row=3, column=0, columnspan=2, padx=14, pady=8)
        def do_pair() -> None:
            try:
                if not Path(path.get().strip()).is_file(): raise RuntimeError("No encuentro sqcli.exe en esa ruta")
                if not code.get().strip(): raise RuntimeError("Falta el código de emparejamiento")
                data = ControlPlane.pair(code.get().strip(), device.get().strip() or socket.gethostname())
                if not data.get("ok"): raise RuntimeError(data.get("error", "pair_failed"))
                new_cfg = BridgeConfig(str(data["device_id"]), str(data.get("device_name") or device.get()), path.get().strip(), False, True)
                new_cfg.save(); keyring.set_password(KEYRING_SERVICE, new_cfg.device_id, str(data["bridge_token"]))
                self.cfg = new_cfg; self.token = str(data["bridge_token"]); self._load_cfg_to_ui(); win.destroy(); self.start_bridge()
            except Exception as exc:
                messagebox.showerror("No se pudo emparejar", str(exc), parent=win)
        ttk.Button(win, text="Emparejar y conectar", command=do_pair).grid(row=4, column=0, columnspan=2, pady=14)

    def test_sqx(self) -> None:
        path = self.cfg.sqcli_path if self.cfg else self.path_var.get()
        def work() -> None:
            try:
                probe_cfg = self.cfg or BridgeConfig("test", "test", path)
                result = sqx_call(probe_cfg, "list_projects", {})
                excerpt = result.get("stdout", "")[:1000]
                self.events.put({"kind": "health", "text": "SQX CLI PASS\n" + excerpt, "tools": sorted(ALLOWLIST)})
            except Exception as exc:
                self.events.put({"kind": "error", "text": f"Prueba SQX: {exc}"})
        threading.Thread(target=work, daemon=True).start()

    def start_bridge(self) -> None:
        if self.worker and self.worker.is_alive(): return
        if not self.cfg or not self.token: self.open_setup(); return
        self.worker = BridgeWorker(self.cfg, self.token, self.events); self.worker.start(); self.status_var.set("Conectando…"); self._log("Iniciando bridge")

    def stop_bridge(self) -> None:
        if self.worker: self.worker.stop()
        self.status_var.set("Detenido")

    def _save_control_flag(self) -> None:
        if self.cfg:
            self.cfg.allow_project_control = bool(self.control_var.get()); self.cfg.save(); self._log("Control de proyectos " + ("habilitado" if self.cfg.allow_project_control else "deshabilitado"))

    def _drain_events(self) -> None:
        while True:
            try: evt = self.events.get_nowait()
            except queue.Empty: break
            kind, text = evt.get("kind"), evt.get("text", "")
            self._log(text)
            if kind == "health": self.status_var.set("Conectado"); self.tools_var.set(", ".join(evt.get("tools") or []))
            elif kind == "error": self.status_var.set("Reintentando")
            elif kind == "state" and "detenido" in text.lower(): self.status_var.set("Detenido")
        self.after(250, self._drain_events)


if __name__ == "__main__":
    App().mainloop()
