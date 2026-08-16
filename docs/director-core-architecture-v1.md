# ContentFlow Director Core Architecture v1

## Objective

ContentFlow uses a single durable Director control path. The Director owns planning, state transitions, dispatch and verification. RARA is an independent support/review/repair service and never becomes a second orchestrator.

## Reference patterns

This design intentionally follows proven orchestration principles found in durable graph/workflow systems:

- explicit workflow state and resumability;
- one authoritative coordinator for state transitions;
- event/history based traceability;
- deterministic state transitions separated from LLM reasoning;
- idempotent retries and bounded concurrency;
- independent review/repair components that cannot abort the main coordinator.

## Director Core cycle

The canonical operational path is:

1. Acquire a per-project advisory lock. If another cycle is active, skip safely.
2. Reconcile orphan claims, leases, backlog/worker/run state and review-gate state.
3. Invoke RARA support logic inside an isolated failure boundary. RARA failures are warnings, never Director-fatal errors.
4. Compute truly dispatchable work. A task is NOT dispatchable if it has any active run in `claimed`, `running` or `review_required`.
5. Compute concurrency from Nexo lane capacity before dispatch. Phase-1 Production capacity is a hard pre-dispatch bound, not something discovered by provider failures.
6. Claim task + create correlated builder run + mark worker running + establish heartbeat/lease as one coherent transactional transition.
7. Execute through the builder runner.
8. Persist review/evidence outcome.
9. Run deterministic post-cycle invariants across backlog, builder_runs and worker_queue.
10. Persist a durable Director cycle record and autonomy event.

## Required invariants

- One active task has at most one active builder run.
- One running worker has exactly one active task.
- Every `claimed/running` run has heartbeat and non-expired lease.
- Backlog selected_model, builder selected_model and worker current_task_key agree.
- A `review_required` run blocks redispatch of its parent task.
- If dispatchable work and capacity exist, Director assigns work without waiting for human intervention.
- Production dispatch never exceeds current configured Nexo Production capacity.
- Duplicate or historical RARA incidents cannot abort a Director cycle.
- Recursive `gap_gap_*` work is never executable.
- Completion requires independent evidence/review; a model assertion alone is not completion.

## Durable state

`director_cycle_runs` records each Director Core cycle with phase, pre-state, post-state, warnings and dispatched count. `contentflow_runtime_event_ledger` remains the run-level execution history. These two levels provide workflow-level and task-level reconstruction.

## RARA boundary

RARA may diagnose, independently review evidence, apply allowlisted reversible repairs and write learning memory. It does not own scheduling, worker assignment, concurrency or backlog lifecycle. Failure or duplicate state inside RARA is isolated and cannot roll back the Director control cycle.

## Legacy paths

`contentflow-auto-loop` is the operational entry point and calls the serialized Director Core. Legacy ranked/supervisor choreography must not act as an independent authority. Any retained legacy endpoint is compatibility-only and must delegate to the Director Core or remain unscheduled.

## Scaling rule

Do not increase concurrency because workers are available. Increase only after measured evidence shows stable cycles with zero active-state mismatches, acceptable provider/QA failure rate, and sufficient Nexo lane headroom.

## Acceptance test for Director Core

Before declaring the Director robust, run repeated cycles and require:

- zero active-state mismatches;
- no orphan claims;
- no duplicate active task/worker ownership;
- no dispatch while an active review exists;
- no cycle-level abort from RARA;
- no dispatch above configured lane capacity;
- productive completion rate measured separately from administrative activity.
