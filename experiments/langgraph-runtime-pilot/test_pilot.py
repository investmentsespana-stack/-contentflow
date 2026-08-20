import os
import sqlite3
import subprocess
import sys
import tempfile
import threading
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
c.execute("update durable_state set generation=2,fencing=2,status='recovered' where project=? and generation=1 and fencing=1", (project,))
c.commit()
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
        resumed = subprocess.run([sys.executable, "-c", RESUME_WORKER, db, project_id], check=False)
        assert resumed.returncode == 0


def test_contentflow_process_crash_restart_persistent_checkpoint_and_fencing():
    run_crash_restart("contentflow")


def test_opc_process_crash_restart_persistent_checkpoint_and_fencing():
    run_crash_restart("opc")


def init_split_brain_db(path: str, project_id: str):
    c = sqlite3.connect(path)
    c.execute("pragma journal_mode=WAL")
    c.execute("create table ownership (project text primary key, generation integer not null, fencing integer not null, owner text, status text not null)")
    c.execute("insert into ownership values (?,1,1,null,'recoverable')", (project_id,))
    c.commit(); c.close()


def contend_for_recovery(path: str, project_id: str, owner: str, barrier: threading.Barrier, results: list):
    c = sqlite3.connect(path, timeout=5, isolation_level=None)
    barrier.wait()
    c.execute("BEGIN IMMEDIATE")
    changed = c.execute(
        "update ownership set generation=2,fencing=2,owner=?,status='owned' where project=? and generation=1 and fencing=1 and owner is null",
        (owner, project_id),
    ).rowcount
    c.commit(); c.close()
    results.append((owner, changed))


def run_split_brain(project_id: str):
    with tempfile.TemporaryDirectory() as td:
        db = str(Path(td) / "splitbrain.sqlite")
        init_split_brain_db(db, project_id)
        barrier = threading.Barrier(2)
        results = []
        t1 = threading.Thread(target=contend_for_recovery, args=(db, project_id, "recovery-a", barrier, results))
        t2 = threading.Thread(target=contend_for_recovery, args=(db, project_id, "recovery-b", barrier, results))
        t1.start(); t2.start(); t1.join(); t2.join()
        assert sorted(changed for _, changed in results) == [0, 1]
        c = sqlite3.connect(db)
        row = c.execute("select generation,fencing,owner,status from ownership where project=?", (project_id,)).fetchone()
        c.close()
        assert row[0:2] == (2,2)
        assert row[2] in {"recovery-a","recovery-b"}
        assert row[3] == "owned"


def test_contentflow_split_brain_single_winner():
    run_split_brain("contentflow")


def test_opc_split_brain_single_winner():
    run_split_brain("opc")


def run_lease_loss_during_resume(project_id: str):
    with tempfile.TemporaryDirectory() as td:
        db = str(Path(td) / "lease-loss.sqlite")
        c = sqlite3.connect(db)
        c.execute("create table task (project text primary key, generation integer, fencing integer, lease_owner text, status text)")
        c.execute("insert into task values (?,2,2,'resumer','resuming')", (project_id,))
        c.commit()
        # Another reconciler legitimately takes ownership before the resumed worker commits.
        c.execute("update task set generation=3,fencing=3,lease_owner='reconciler',status='reassigned' where project=? and generation=2 and fencing=2", (project_id,))
        c.commit()
        # Resumed worker is stale: conditional completion with old generation/fencing must be rejected.
        changed = c.execute("update task set status='completed' where project=? and generation=2 and fencing=2 and lease_owner='resumer'", (project_id,)).rowcount
        c.commit()
        row = c.execute("select generation,fencing,lease_owner,status from task where project=?", (project_id,)).fetchone()
        c.close()
        assert changed == 0
        assert row == (3,3,'reconciler','reassigned')


def test_contentflow_lease_loss_during_resume_rejects_stale_completion():
    run_lease_loss_during_resume("contentflow")


def test_opc_lease_loss_during_resume_rejects_stale_completion():
    run_lease_loss_during_resume("opc")
