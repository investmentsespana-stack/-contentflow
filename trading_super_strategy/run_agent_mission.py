from __future__ import annotations

import json
from pathlib import Path

from agent_orchestrator import DirectorOrchestrator, ResearchTask, default_agent_pool


ROOT = Path(__file__).resolve().parent
CONFIG = ROOT / "agent_pool_config.json"
OUTPUT_DIR = ROOT / "agent_mission_output"


def main() -> None:
    config = json.loads(CONFIG.read_text(encoding="utf-8"))
    director = DirectorOrchestrator(
        default_agent_pool(),
        max_attempts_before_block=int(config["director_cycle"]["max_attempts_before_block"]),
    )

    tasks = [
        ResearchTask(
            task_id=row["task_id"],
            task_type=row["task_type"],
            payload={"objective": row["objective"], "mode": config["mode"]},
        )
        for row in config["initial_parallel_mission"]
    ]
    assignments = director.assign_parallel(tasks)

    report = {
        "version": config["version"],
        "mode": config["mode"],
        "live_money": config["live_money"],
        "order_execution_authority_for_agents": config["order_execution_authority_for_agents"],
        "assignments": [
            {
                "task_id": a.task_id,
                "agent": a.agent_name,
                "model_slot": a.model_slot,
                "reason": a.reason,
                "state": next(t.state.value for t in tasks if t.task_id == a.task_id),
                "objective": next(t.payload["objective"] for t in tasks if t.task_id == a.task_id),
            }
            for a in assignments
        ],
    }

    OUTPUT_DIR.mkdir(exist_ok=True)
    (OUTPUT_DIR / "assignments.json").write_text(json.dumps(report, indent=2), encoding="utf-8")

    print("AGENT_MISSION_ASSIGNED")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
