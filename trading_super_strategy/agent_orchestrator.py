from __future__ import annotations

from dataclasses import dataclass, field
from enum import Enum
from typing import Any, Dict, Iterable, List, Mapping, Optional, Sequence, Tuple


class TaskState(str, Enum):
    PENDING = "PENDING"
    CLAIMED = "CLAIMED"
    RUNNING = "RUNNING"
    VERIFYING = "VERIFYING"
    DONE = "DONE"
    BLOCKED = "BLOCKED"


@dataclass(frozen=True)
class AgentSpec:
    name: str
    role: str
    capabilities: Tuple[str, ...]
    model_slot: str
    can_execute_orders: bool = False


@dataclass
class ResearchTask:
    task_id: str
    task_type: str
    payload: Dict[str, Any] = field(default_factory=dict)
    required_capability: Optional[str] = None
    state: TaskState = TaskState.PENDING
    assigned_agent: Optional[str] = None
    attempts: int = 0
    last_error: Optional[str] = None
    qa_required: bool = True
    qa_approved: bool = False


@dataclass(frozen=True)
class Assignment:
    task_id: str
    agent_name: str
    model_slot: str
    reason: str


@dataclass(frozen=True)
class ReviewDecision:
    task_id: str
    approved: bool
    next_state: TaskState
    next_agent: Optional[str]
    reason: str


class DirectorOrchestrator:
    """Deterministic research-task router for the Super Estrategia.

    LLM/AI agents may research, generate hypotheses and review evidence, but no
    agent is ever allowed to place broker orders. Execution remains behind the
    deterministic Risk Manager + Execution Gateway, and live money stays off.
    """

    HARD_BLOCKED_TASK_TYPES = {
        "place_live_order",
        "send_live_order",
        "enable_live_money",
        "broker_flatten_live",
        "broker_cancel_live",
    }

    DEFAULT_TASK_CAPABILITY: Mapping[str, str] = {
        "strategy_generation": "strategy_research",
        "coalition_discovery": "coalition_research",
        "backtest": "backtest",
        "walk_forward": "backtest",
        "monte_carlo": "robustness",
        "anti_overfit": "robustness",
        "experiment_audit": "robustness",
        "prop_firm_simulation": "prop_firm",
        "macro_context": "macro_fundamental",
        "microstructure_research": "order_flow",
        "multimodal_context": "multimodal_fusion",
        "news_encoding": "multimodal_fusion",
        "data_quality": "data_quality",
        "qa_review": "qa_judge",
        "repair": "repair",
    }

    def __init__(self, agents: Sequence[AgentSpec], *, max_attempts_before_block: int = 3) -> None:
        self.agents = {a.name: a for a in agents}
        self.max_attempts_before_block = max_attempts_before_block
        self._validate_agent_pool()

    def _validate_agent_pool(self) -> None:
        if not self.agents:
            raise ValueError("agent pool cannot be empty")
        if any(a.can_execute_orders for a in self.agents.values()):
            raise ValueError("research agents must never have broker execution authority")
        required = {"director", "qa_judge", "repair"}
        roles = {a.role for a in self.agents.values()}
        missing = required - roles
        if missing:
            raise ValueError(f"missing mandatory agent roles: {sorted(missing)}")

    @staticmethod
    def _is_execution_request(task: ResearchTask) -> bool:
        text = " ".join(
            [task.task_type]
            + [str(k) for k in task.payload.keys()]
            + [str(v) for v in task.payload.values()]
        ).lower()
        return task.task_type in DirectorOrchestrator.HARD_BLOCKED_TASK_TYPES or (
            "live" in text and any(token in text for token in ("order", "broker", "execute", "trade"))
        )

    def _capability_for(self, task: ResearchTask) -> str:
        if task.required_capability:
            return task.required_capability
        return self.DEFAULT_TASK_CAPABILITY.get(task.task_type, task.task_type)

    def _candidates(self, capability: str) -> List[AgentSpec]:
        return [a for a in self.agents.values() if capability in a.capabilities]

    def assign(self, task: ResearchTask) -> Assignment:
        if self._is_execution_request(task):
            task.state = TaskState.BLOCKED
            task.last_error = "LIVE_EXECUTION_FORBIDDEN_FOR_AGENT_POOL"
            raise PermissionError(task.last_error)
        if task.state not in {TaskState.PENDING, TaskState.BLOCKED}:
            raise ValueError(f"task {task.task_id} is not assignable from {task.state}")
        if task.attempts >= self.max_attempts_before_block:
            task.state = TaskState.BLOCKED
            task.last_error = "MAX_ATTEMPTS_REACHED"
            raise RuntimeError(task.last_error)

        capability = self._capability_for(task)
        candidates = self._candidates(capability)
        if not candidates:
            task.state = TaskState.BLOCKED
            task.last_error = f"NO_AGENT_FOR_CAPABILITY:{capability}"
            raise LookupError(task.last_error)

        chosen = sorted(candidates, key=lambda a: (a.model_slot, a.name))[0]
        task.assigned_agent = chosen.name
        task.state = TaskState.CLAIMED
        task.attempts += 1
        return Assignment(task.task_id, chosen.name, chosen.model_slot, f"CAPABILITY:{capability}")

    def start(self, task: ResearchTask) -> None:
        if task.state != TaskState.CLAIMED:
            raise ValueError("task must be CLAIMED before RUNNING")
        task.state = TaskState.RUNNING

    def submit_for_review(self, task: ResearchTask) -> None:
        if task.state != TaskState.RUNNING:
            raise ValueError("task must be RUNNING before VERIFYING")
        task.state = TaskState.VERIFYING

    def review(self, task: ResearchTask, *, approved: bool, reason: str = "") -> ReviewDecision:
        if task.state != TaskState.VERIFYING:
            raise ValueError("task must be VERIFYING before QA review")
        if approved:
            task.qa_approved = True
            task.state = TaskState.DONE
            return ReviewDecision(task.task_id, True, TaskState.DONE, None, reason or "QA_APPROVED")

        task.qa_approved = False
        task.last_error = reason or "QA_REJECTED"
        if task.attempts >= self.max_attempts_before_block:
            task.state = TaskState.BLOCKED
            return ReviewDecision(task.task_id, False, TaskState.BLOCKED, None, "MAX_ATTEMPTS_REACHED")

        repair_agents = sorted(
            (a for a in self.agents.values() if "repair" in a.capabilities),
            key=lambda a: (a.model_slot, a.name),
        )
        if not repair_agents:
            task.state = TaskState.BLOCKED
            return ReviewDecision(task.task_id, False, TaskState.BLOCKED, None, "NO_REPAIR_AGENT")

        repair = repair_agents[0]
        task.assigned_agent = repair.name
        task.state = TaskState.CLAIMED
        task.attempts += 1
        return ReviewDecision(task.task_id, False, TaskState.CLAIMED, repair.name, "ROUTED_TO_REPAIR")

    def assign_parallel(self, tasks: Iterable[ResearchTask]) -> List[Assignment]:
        assignments: List[Assignment] = []
        for task in tasks:
            assignments.append(self.assign(task))
        return assignments


def default_agent_pool() -> List[AgentSpec]:
    return [
        AgentSpec("director", "director", ("planning", "coordination", "data_quality"), "production"),
        AgentSpec("strategy_builder", "research", ("strategy_research",), "production"),
        AgentSpec("coalition_researcher", "research", ("coalition_research",), "production"),
        AgentSpec("backtest_agent", "research", ("backtest",), "production"),
        AgentSpec("robustness_agent", "research", ("robustness",), "production"),
        AgentSpec("prop_firm_agent", "research", ("prop_firm",), "production"),
        AgentSpec("macro_agent", "research", ("macro_fundamental",), "production"),
        AgentSpec("microstructure_agent", "research", ("order_flow",), "production"),
        AgentSpec("multimodal_fusion_agent", "research", ("multimodal_fusion",), "production"),
        AgentSpec("qa_judge", "qa_judge", ("qa_judge",), "qa_judge"),
        AgentSpec("rara_repair", "repair", ("repair",), "fallback"),
    ]
