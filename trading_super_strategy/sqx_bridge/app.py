from __future__ import annotations

import asyncio
import json
import os
import queue
import socket
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import httpx
import keyring
import tkinter as tk
from tkinter import messagebox, ttk

from mcp import ClientSession
from mcp.client.streamable_http import streamablehttp_client

APP_NAME = "Cygnus SQX Bridge"
KEYRING_SERVICE = "CygnusSQXBridge"
CONTROL_URL = "https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/sqx-bridge"
DEFAULT_SQX_MCP = "http://localhost:8080/mcp"
ALLOWLIST = {
    "list_projects",
    "list_strategies",
    "list_databanks",
    "get_strategy_stats",
    "run_project",
    "stop_project",
}
READ_ONLY = {
    "list_projects",
    "list_strategies",
    "list_databanks",
    "get_strategy_stats",
}


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
    sqx_mcp_url: str = DEFAULT_SQX_MCP
    allow_project_control: bool = False
    auto_start: bool = True

    @classmethod
    def load(cls) -> "BridgeConfig | None":
        if not CONFIG_PATH.exists():
            return None
        raw = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
        return cls(**raw)

    def save(self) -> None:
        CONFIG_PATH.write_text(json.dumps(self.__dict__, indent=2), encoding="utf-8")


class ControlPlane:
    def __init__(self, token: str):
        self.token = token
        self.client = httpx.Client(timeout=15.0)

    def post(self, body: dict[str, Any]) -> dict[str, Any]:
        headers = {"Authorization": f"Bearer {self.token}"} if self.token else {}
        r = self.client.post(CONTROL_URL, json=body, headers=headers)
        r.raise_for_status()
        return r.json()

    @staticmethod
    def pair(code: str, device_name: str) -> dict[str, Any]:
        with httpx.Client(timeout=15.0) as c:
            r = c.post(CONTROL_URL, json={"action": "pair", "code": code, "device_name": device_name})
            r.raise_for_status()
            return r.json()


async def sqx_list_tools(url: str) -> list[dict[str, Any]]:
    async with streamablehttp_client(url) as transport:
        read, write = transport[0], transport[1]
        async with ClientSession(read, write) as session:
            await session.initialize()
            result = await session.list_tools()
            tools = []
            for t in result.tools:
                if hasattr(t, "model_dump"):
                    tools.append(t.model_dump(mode="json"))
                else:
                    tools.append({"name": getattr(t, "name", str(t))})
            return tools


async def sqx_call(url: str, name: str, arguments: dict[str, Any]) -> dict[str, Any]:
    if name not in ALLOWLIST:
        raise RuntimeError(f"Command not allowlisted: {name}")
    async with streamablehttp_client(url) as transport:
        read, write = transport[0], transport[1]
        async with ClientSession(read, write) as session:
            await session.initialize()
            tools = await session.list_tools()
            names = {t.name for t in tools.tools}
            if name not in names:
                raise RuntimeError(f"SQX MCP tool unavailable: {name}; available={sorted(names)}")
            result = await session.call_tool(name, arguments=arguments or {})
            if hasattr(result, "model_dump"):
                return result.model_dump(mode="json")
            return {"value": str(result)}


class BridgeWorker(threading.Thread):
    def __init__(self, cfg: BridgeConfig, token: str, events: queue.Queue):
        super().__init__(daemon=True)
        self.cfg = cfg
        self.token = token
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
                if time.time() - self.last_heartbeat > 30:
                    tools = asyncio.run(sqx_list_tools(self.cfg.sqx_mcp_url))
                    tool_names = sorted(t.get("name", "") for t in tools)
                    health = {
                        "hostname": socket.gethostname(),
                        "sqx_mcp_url": self.cfg.sqx_mcp_url,
                        "sqx_tools": tool_names,
                        "project_control_enabled": self.cfg.allow_project_control,
                    }
                    self.control.post({"action": "heartbeat", "health": health})
                    self.last_heartbeat = time.time()
                    self.emit("health", f"SQX conectado · {len(tool_names)} tools", tools=tool_names)

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

                if ctype not in ALLOWLIST:
                    raise RuntimeError(f"Command blocked by local allowlist: {ctype}")
                if ctype not in READ_ONLY and not self.cfg.allow_project_control:
                    raise RuntimeError("Project start/stop is disabled locally")

                try:
                    result = asyncio.run(sqx_call(self.cfg.sqx_mcp_url, ctype, payload))
                    self.control.post({
                        "action": "complete",
                        "command_id": cid,
                        "claim_nonce": nonce,
                        "success": True,
                        "result": result,
                    })
                    self.emit("command", f"Completado {ctype}", command_id=cid)
                except Exception as exc:
                    self.control.post({
                        "action": "complete",
                        "command_id": cid,
                        "claim_nonce": nonce,
                        "success": False,
                        "error": str(exc),
                    })
                    self.emit("error", f"{ctype}: {exc}", command_id=cid)

            except Exception as exc:
                self.emit("error", str(exc))
                time.sleep(8)

        self.emit("state", "Bridge detenido")


class App(tk.Tk):
    def __init__(self):
        super().__init__()
        self.title(APP_NAME)
        self.geometry("640x440")
        self.minsize(600, 400)
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
                self._log("No se encontró el token local. Empareja de nuevo.")
        else:
            self.after(300, self.open_setup)

    def _build_ui(self) -> None:
        pad = {"padx": 12, "pady": 8}
        top = ttk.Frame(self)
        top.pack(fill="x", **pad)
        ttk.Label(top, text="Cygnus SQX Bridge", font=("Segoe UI", 16, "bold")).pack(side="left")
        self.status_var = tk.StringVar(value="No conectado")
        ttk.Label(top, textvariable=self.status_var).pack(side="right")

        info = ttk.LabelFrame(self, text="Conexión")
        info.pack(fill="x", **pad)
        self.device_var = tk.StringVar(value="—")
        self.mcp_var = tk.StringVar(value=DEFAULT_SQX_MCP)
        self.tools_var = tk.StringVar(value="—")
        rows = [("Dispositivo", self.device_var), ("SQX MCP", self.mcp_var), ("Tools", self.tools_var)]
        for i, (label, var) in enumerate(rows):
            ttk.Label(info, text=label, width=14).grid(row=i, column=0, sticky="w", padx=8, pady=4)
            ttk.Label(info, textvariable=var).grid(row=i, column=1, sticky="w", padx=8, pady=4)

        buttons = ttk.Frame(self)
        buttons.pack(fill="x", **pad)
        ttk.Button(buttons, text="Configurar / Emparejar", command=self.open_setup).pack(side="left", padx=4)
        ttk.Button(buttons, text="Probar SQX", command=self.test_sqx).pack(side="left", padx=4)
        ttk.Button(buttons, text="Iniciar", command=self.start_bridge).pack(side="left", padx=4)
        ttk.Button(buttons, text="Detener", command=self.stop_bridge).pack(side="left", padx=4)

        self.control_var = tk.BooleanVar(value=False)
        ttk.Checkbutton(
            self,
            text="Permitir iniciar/detener proyectos de investigación en StrategyQuant",
            variable=self.control_var,
            command=self._save_control_flag,
        ).pack(anchor="w", padx=18, pady=4)

        logframe = ttk.LabelFrame(self, text="Actividad")
        logframe.pack(fill="both", expand=True, **pad)
        self.log = tk.Text(logframe, height=12, wrap="word", state="disabled")
        self.log.pack(fill="both", expand=True, padx=6, pady=6)

    def _log(self, text: str) -> None:
        stamp = time.strftime("%H:%M:%S")
        self.log.configure(state="normal")
        self.log.insert("end", f"[{stamp}] {text}\n")
        self.log.see("end")
        self.log.configure(state="disabled")

    def _load_cfg_to_ui(self) -> None:
        if not self.cfg:
            return
        self.device_var.set(f"{self.cfg.device_name} · {self.cfg.device_id[:8]}")
        self.mcp_var.set(self.cfg.sqx_mcp_url)
        self.control_var.set(self.cfg.allow_project_control)

    def open_setup(self) -> None:
        win = tk.Toplevel(self)
        win.title("Configurar SQX Bridge")
        win.geometry("560x300")
        win.grab_set()

        device = tk.StringVar(value=self.cfg.device_name if self.cfg else socket.gethostname())
        mcp = tk.StringVar(value=self.cfg.sqx_mcp_url if self.cfg else DEFAULT_SQX_MCP)
        code = tk.StringVar(value="")

        fields = [("Nombre del PC", device), ("URL MCP de SQX", mcp), ("Código de emparejamiento", code)]
        for i, (label, var) in enumerate(fields):
            ttk.Label(win, text=label).grid(row=i, column=0, sticky="w", padx=14, pady=10)
            ttk.Entry(win, textvariable=var, width=48).grid(row=i, column=1, sticky="ew", padx=14, pady=10)
        win.columnconfigure(1, weight=1)

        ttk.Label(win, text="El código es de un solo uso y expira. El token permanente se guarda en el almacén seguro de Windows.", wraplength=500).grid(row=3, column=0, columnspan=2, padx=14, pady=8)

        def do_pair() -> None:
            try:
                if not code.get().strip():
                    raise RuntimeError("Falta el código de emparejamiento")
                data = ControlPlane.pair(code.get().strip(), device.get().strip() or socket.gethostname())
                if not data.get("ok"):
                    raise RuntimeError(data.get("error", "pair_failed"))
                new_cfg = BridgeConfig(
                    device_id=str(data["device_id"]),
                    device_name=str(data.get("device_name") or device.get()),
                    sqx_mcp_url=mcp.get().strip() or DEFAULT_SQX_MCP,
                    allow_project_control=False,
                    auto_start=True,
                )
                new_cfg.save()
                keyring.set_password(KEYRING_SERVICE, new_cfg.device_id, str(data["bridge_token"]))
                self.cfg = new_cfg
                self.token = str(data["bridge_token"])
                self._load_cfg_to_ui()
                self._log("Emparejamiento seguro completado")
                win.destroy()
                self.start_bridge()
            except Exception as exc:
                messagebox.showerror("No se pudo emparejar", str(exc), parent=win)

        ttk.Button(win, text="Emparejar y conectar", command=do_pair).grid(row=4, column=0, columnspan=2, pady=14)

    def test_sqx(self) -> None:
        url = self.cfg.sqx_mcp_url if self.cfg else self.mcp_var.get()
        def work():
            try:
                tools = asyncio.run(sqx_list_tools(url))
                names = [t.get("name", "") for t in tools]
                self.events.put({"kind": "health", "text": f"SQX conectado · {len(names)} tools", "tools": names})
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
            self._log("Control de proyectos " + ("habilitado" if self.cfg.allow_project_control else "deshabilitado"))

    def _drain_events(self) -> None:
        while True:
            try:
                evt = self.events.get_nowait()
            except queue.Empty:
                break
            kind = evt.get("kind")
            text = evt.get("text", "")
            self._log(text)
            if kind == "health":
                self.status_var.set("Conectado")
                tools = evt.get("tools") or []
                self.tools_var.set(", ".join(tools) if tools else "—")
            elif kind == "error":
                self.status_var.set("Reintentando")
            elif kind == "state" and "detenido" in text.lower():
                self.status_var.set("Detenido")
        self.after(250, self._drain_events)


if __name__ == "__main__":
    App().mainloop()
