from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from hashlib import sha256
from typing import Dict, List


LIVE_MONEY = False


class Mode(str, Enum):
    PAPER = "paper"
    SIM = "sim"
    SHADOW = "shadow"


class OrderState(str, Enum):
    ACCEPTED = "accepted"
    REJECTED = "rejected"
    DUPLICATE = "duplicate"
    FLATTENED = "flattened"


@dataclass(frozen=True)
class Decision:
    brain_run_id: str
    timestamp_ns: int
    symbol: str
    side: str
    quantity: int
    stop_distance: float
    data_safe: bool = True

    @property
    def decision_id(self) -> str:
        payload = f"{self.brain_run_id}|{self.timestamp_ns}|{self.symbol}|{self.side}|{self.quantity}|{self.stop_distance}"
        return sha256(payload.encode()).hexdigest()


@dataclass
class ExecutionResult:
    decision_id: str
    state: OrderState
    reason: str


@dataclass
class DeterministicExecutionGateway:
    mode: Mode = Mode.SIM
    max_loss_r: float = 3.0
    processed: Dict[str, ExecutionResult] = field(default_factory=dict)
    net_loss_r: float = 0.0
    killed: bool = False
    open_positions: Dict[str, int] = field(default_factory=dict)
    audit: List[ExecutionResult] = field(default_factory=list)

    def submit(self, decision: Decision) -> ExecutionResult:
        if LIVE_MONEY:
            raise RuntimeError("live money must remain disabled in V1")
        if decision.decision_id in self.processed:
            return ExecutionResult(decision.decision_id, OrderState.DUPLICATE, "idempotent_duplicate")
        if self.killed:
            return self._record(decision, OrderState.REJECTED, "kill_switch_active")
        if not decision.data_safe:
            self.emergency_flatten("DATA_UNSAFE")
            return self._record(decision, OrderState.REJECTED, "DATA_UNSAFE")
        if decision.quantity <= 0 or decision.stop_distance <= 0:
            return self._record(decision, OrderState.REJECTED, "protective_stop_required")
        if self.net_loss_r >= self.max_loss_r:
            self.emergency_flatten("hard_max_loss")
            return self._record(decision, OrderState.REJECTED, "hard_max_loss")
        signed = decision.quantity if decision.side.upper() == "BUY" else -decision.quantity
        self.open_positions[decision.symbol] = self.open_positions.get(decision.symbol, 0) + signed
        return self._record(decision, OrderState.ACCEPTED, f"{self.mode.value}_only")

    def apply_loss(self, loss_r: float) -> None:
        self.net_loss_r += max(0.0, loss_r)
        if self.net_loss_r >= self.max_loss_r:
            self.emergency_flatten("hard_max_loss")

    def emergency_flatten(self, reason: str) -> None:
        self.open_positions.clear()
        self.killed = True
        marker = ExecutionResult("SYSTEM", OrderState.FLATTENED, reason)
        self.audit.append(marker)

    def reconcile(self, broker_positions: Dict[str, int]) -> bool:
        # In sim/shadow the external simulator is authoritative after reconnect.
        self.open_positions = dict(broker_positions)
        return True

    def _record(self, decision: Decision, state: OrderState, reason: str) -> ExecutionResult:
        result = ExecutionResult(decision.decision_id, state, reason)
        self.processed[decision.decision_id] = result
        self.audit.append(result)
        return result
