# ContentFlow Director Core V2 — Architecture Benchmark

## Goal
Build a durable, autonomous multi-agent orchestration core that separates deterministic workflow state from probabilistic agent reasoning.

## Primary-source architectures reviewed

### Temporal
Adopted principles: durable execution, replayable history, idempotency, failure isolation, resumable workflows, and explicit retry policy with bounded backoff rather than blind immediate retry.
ContentFlow mapping: `director_cycle_runs`, `director_state_transition_ledger`, `idempotency_key`, heartbeat/lease recovery, serialized Director cycle, `contentflow_retry_policies`, `contentflow_retry_state`, retry classification, exponential backoff, cooldown and open-circuit states.

### LangGraph
Adopted principles: long-running stateful orchestration, durable execution, checkpointing, human-in-the-loop, memory, and traceability.
ContentFlow mapping: durable cycle checkpoints, explicit state transitions, HELP path, persistent error memory, trace IDs.

### Microsoft Agent Framework
Adopted principles: production-grade workflows, graph patterns, checkpointing, middleware/failure boundaries, observability, provider flexibility, declarative/versioned agents/workflows, and canary-style validation before scale.
ContentFlow mapping: workflow version registry, RARA failure boundary, provider lanes, capacity planning, canary parallelism, cross-cutting retry policy and structured workflow telemetry.

### OpenTelemetry
Adopted principles: traces made of spans, context propagation, span status, structured attributes/events, and correlation rather than unstructured logs.
ContentFlow mapping: `trace_id`, `span_id`, `director_trace_spans`, runtime event correlation, span status/duration/error class, and telemetry that excludes raw prompts/outputs by default.

### OpenAI Agents SDK
Adopted principles: explicit handoffs, guardrails, sessions/history, tracing, agents-as-tools, human-in-the-loop, and guardrails at operational boundaries instead of only first input/final output.
ContentFlow mapping: Director remains authority; Builder/Judge/RARA are delegated roles; runtime event ledger + trace/span IDs; input/output/tool/deploy review boundaries; HELP path.

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
11. Transient failures use bounded retry/backoff; non-transient quality/evidence failures require repair or strategy change.
12. Dispatcher cannot bypass `next_eligible_at` or an open retry circuit.
13. Only the latest absolute run of a non-completed task can create retry state.
14. Every builder run has a correlated span with status and timing metadata; raw sensitive prompt/output data is not stored in span attributes by default.

## Retry classification
Transient / automatically retryable:
- `capacity`: Nexo lane saturation; exponential backoff, model may rotate.
- `judge`: Judge unavailable/unparseable; preserve builder result and retry review path.
- `provider`: provider failure; bounded retry and model rotation.
- `timeout`: bounded exponential backoff.
- `state_recovery`: orphan/lease/stale recovery; short cooldown before fresh claim.

Non-transient / no blind retry:
- `quality_review`
- `quality_gate`
- `acceptance_evidence`
- `unknown`

These open a circuit and hold the task for Director/RARA diagnosis or a changed strategy.

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
- `contentflow_retry_policies`
- `contentflow_retry_state`
- `contentflow_classify_run_error()`
- `contentflow_apply_retry_policy()`
- `contentflow_reconcile_retry_policies()`
- dispatcher enforcement for cooldown/open circuits
- `director_trace_spans`
- builder `span_id` + runtime-event span propagation
- `contentflow_trace_health` view

## Scale policy
Bootstrap/degraded: 3 new Production workers maximum per canary decision.
Stable: up to 6 concurrent Production workers, bounded by live Nexo `production_max`.
Promotion requires clean Director cycles and acceptable recent builder failure rate.

## Validation target
Before increasing autonomy or adding features, require repeated cycles with:
- 0 active state mismatches
- 0 orphan claims
- 0 duplicate active ownership
- 0 Director aborts caused by support services
- valid trace IDs, span IDs and workflow versions
- bounded retry behavior with no immediate retry storms
- real completed backlog growth, not only administrative events

## Latest validation
A post-hardening Director Core V2 validation completed with:
- `dispatched=3`
- `workers_running=6`
- `production_max=6`
- `capacity_respected=true`
- `active_state_mismatches=0`
- `warnings=[]`

An initial historical retry reconciliation was intentionally corrected after validation showed it could classify superseded failures. The retry reconciler now only acts when the failed/deferred run is the latest absolute run for a non-completed task, and obsolete retry state is removed.

## Architectural rule
Do not add another orchestrator path. New capabilities must plug into Director Core as deterministic stages, support services, middleware-style cross-cutting policy, or delegated agents. RARA supports the Director; it does not replace it.
