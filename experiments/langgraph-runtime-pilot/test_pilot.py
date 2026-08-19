import os
import sqlite3
import subprocess
import sys
import tempfile
from pathlib import Path
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
    decision = interrupt({"project_id": state["project_id"], "runtime_role": state["runtime_role"], "checkpoint": state["checkpoint"], "external_effects": False})
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
    initial = graph.invoke({"project_id": project_id, "runtime_role": "adapter-only", "checkpoint": "none", "status": "pending"}, config=config)
    assert initial["checkpoint"] == "last-safe-state"
    assert "__interrupt__" in initial
    resumed = graph.invoke(Command(resume=True), config=config)
    assert resumed["status"] == "approved"


def test_contentflow_langgraph_checkpoint_and_resume():
    run_project("contentflow")


def test_opc_langgraph_checkpoint_and_resume():
    run_project("opc")


CRASH_WORKER = r'''
import os, sqlite3, sys
p=sys.argv[1]
c=sqlite3.connect(p)
c.execute("create table if not exists durable_state (project text primary key, generation integer, fencing integer, checkpoint text, status text)")
c.execute("insert or replace into durable_state values (?, ?, ?, ?, ?)", (sys.argv[2], 1, 1, "last-safe-state", "running"))
c.commit(); c.close()
os._exit(73)
'''

RESUME_WORKER = r'''
import sqlite3, sys
p, project=sys.argv[1], sys.argv[2]
c=sqlite3.connect(p)
row=c.execute("select generation,fencing,checkpoint,status from durable_state where project=?", (project,)).fetchone()
assert row == (1,1,"last-safe-state","running")
# Director reconciliation after crash takes a new fenced generation.
c.execute("update durable_state set generation=2,fencing=2,status='recovered' where project=? and generation=1 and fencing=1", (project,))
c.commit()
# A stale worker carrying fencing=1 must no longer own the task.
accepted=c.execute("select count(*) from durable_state where project=? and generation=2 and fencing=1", (project,)).fetchone()[0]
assert accepted == 0
row=c.execute("select generation,fencing,checkpoint,status from durable_state where project=?", (project,)).fetchone()
assert row == (2,2,"last-safe-state","recovered")
c.close()
'''


def run_crash_restart(project_id: str):
    with tempfile.TemporaryDirectory() as td:
        db = str(Path(td) / "checkpoint.sqlite")
        crashed = subprocess.run([sys.executable, "-c", CRASH_WORKER, db, project_id], check=False)
        assert crashed.returncode == 73
        # New process proves the durable checkpoint survived process death.
        resumed = subprocess.run([sys.executable, "-c", RESUME_WORKER, db, project_id], check=False)
        assert resumed.returncode == 0


def test_contentflow_process_crash_restart_persistent_checkpoint_and_fencing():
    run_crash_restart("contentflow")


def test_opc_process_crash_restart_persistent_checkpoint_and_fencing():
    run_crash_restart("opc")
