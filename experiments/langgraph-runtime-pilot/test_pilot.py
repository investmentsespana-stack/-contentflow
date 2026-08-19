from typing import Literal, Optional, TypedDict

from langgraph.checkpoint.memory import InMemorySaver
from langgraph.graph import END, START, StateGraph
from langgraph.types import Command, interrupt


class PilotState(TypedDict):
    project_id: str
    runtime_role: Literal["adapter-only"]
    checkpoint: str
    status: Optional[Literal["pending", "approved", "rejected"]]


def checkpoint_node(state: PilotState):
    assert state["runtime_role"] == "adapter-only"
    assert state["project_id"] in {"contentflow", "opc"}
    return {"checkpoint": "last-safe-state"}


def approval_node(state: PilotState) -> Command[Literal["finish", "cancel"]]:
    decision = interrupt(
        {
            "project_id": state["project_id"],
            "runtime_role": state["runtime_role"],
            "checkpoint": state["checkpoint"],
            "external_effects": False,
            "question": "Resume deterministic sandbox workflow?",
        }
    )
    return Command(goto="finish" if decision else "cancel")


def finish_node(state: PilotState):
    return {"status": "approved"}


def cancel_node(state: PilotState):
    return {"status": "rejected"}


def build_graph():
    builder = StateGraph(PilotState)
    builder.add_node("checkpoint", checkpoint_node)
    builder.add_node("approval", approval_node)
    builder.add_node("finish", finish_node)
    builder.add_node("cancel", cancel_node)
    builder.add_edge(START, "checkpoint")
    builder.add_edge("checkpoint", "approval")
    builder.add_edge("finish", END)
    builder.add_edge("cancel", END)
    return builder.compile(checkpointer=InMemorySaver())


def run_project(project_id: str):
    graph = build_graph()
    config = {"configurable": {"thread_id": f"pilot-{project_id}"}}
    initial = graph.invoke(
        {
            "project_id": project_id,
            "runtime_role": "adapter-only",
            "checkpoint": "none",
            "status": "pending",
        },
        config=config,
    )

    assert initial["checkpoint"] == "last-safe-state"
    assert "__interrupt__" in initial
    assert initial["status"] == "pending"

    resumed = graph.invoke(Command(resume=True), config=config)
    assert resumed["checkpoint"] == "last-safe-state"
    assert resumed["runtime_role"] == "adapter-only"
    assert resumed["status"] == "approved"


def test_contentflow_langgraph_checkpoint_and_resume():
    run_project("contentflow")


def test_opc_langgraph_checkpoint_and_resume():
    run_project("opc")
