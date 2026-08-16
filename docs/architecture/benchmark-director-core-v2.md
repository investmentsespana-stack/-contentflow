# ContentFlow Director Core V2 — Architecture Benchmark

## Goal
Build a durable, autonomous multi-agent orchestration core that separates deterministic workflow state from probabilistic agent reasoning.

## Primary-source architectures reviewed

### Temporal
Adopted principles: durable execution, replayable history, idempotency, failure isolation, and resumable workflows.
ContentFlow mapping: `director_cycle_runs`, `director_state_transition_ledger`, `idempotency_key`, heartbeat/lease recovery, serialized Director cycle.

### LangGraph
Adopted principles: long-running stateful orchestration, durable execution, checkpointing, human-in-the-loop, memory, and traceability.
ContentFlow mapping: durable cycle checkpoints, explicit state transitions, HELP path, persistent error memory, trace IDs.

### Microsoft Agent Framework
Adopted principles: production-grade workflows, graph patterns, checkpointing, middleware/failure boundaries, observability, provider flexibility, declarative/versioned agents/workflows, and canary-style validation before scale.
ContentFlow mapping: workflow version registry, RARA failure boundary, provider lanes, capacity planning, canary parallelism.

### OpenAI Agents SDK
Adopted principles: explicit handoffs, guardrails, sessions/history, tracing, agents-as-tools, human-in-the-loop.
ContentFlow mapping: Director remains authority; Builder/Judge/RARA are delegated roles; runtime event ledger + trace ID; guardrail review boundaries; HELP path.

### AutoGen lessons / Microsoft migration path
Adopted principles: layered responsibilities, event-driven runtime, benchmarking/evals; avoid treating prototyping UI/orchestration as production runtime.
ContentFlow mapping: Director Core separated from agent layer, canary gate, persistent benchmark/quality metrics.

## ContentFlow V2 invariants
1. One active task -> one active builder run -> one worker owner.
2. Every active run has heartbeat and valid lease.
3. Backlog, builder run, and worker queue must agree after every Director cycle.
4. A task with an active `claimed`, `running`, or `review_required` run is not dispatchable.
5. RARA is support-only and cannot abort Director control flow.
6. Director cycles are serialized by advisory lock.
7. Every new cycle and builder run carries `workflow_version` and `trace_id`.
8. State transitions are written to an append-only transition ledger.
9. Production parallelism is bounded before dispatch by Nexo lane capacity.
10. Scale-up is gated by recent clean cycles and failure rate.

## Implemented V2 components
- `director_workflow_versions`
- `director-core-v2` active version
- `workflow_version` + `trace_id` on Director cycles, builder runs, runtime events
- `director_state_transition_ledger`
- transition triggers for backlog, builder runs, and workers
- `contentflow_recommended_parallelism()`
- `director_canary_policy`
- `contentflow_director_core_cycle_auto()`
- `contentflow-auto-loop` v25 with bounded planner wait and asynchronous RARA support

## Scale policy
Bootstrap/degraded: 3 Production workers maximum.
Stable: up to 6, bounded by live Nexo `production_max`.
Promotion requires clean Director cycles and acceptable recent builder failure rate.

## Validation target
Before increasing autonomy or adding features, require repeated cycles with:
- 0 active state mismatches
- 0 orphan claims
- 0 duplicate active ownership
- 0 Director aborts caused by support services
- valid trace IDs and workflow versions
- real completed backlog growth, not only administrative events

## Architectural rule
Do not add another orchestrator path. New capabilities must plug into Director Core as deterministic stages, support services, or delegated agents. RARA supports the Director; it does not replace it.
