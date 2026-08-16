# ContentFlow Director Core V2 — Architecture Benchmark

## Goal
Build a durable, autonomous multi-agent orchestration core that separates deterministic workflow state from probabilistic agent reasoning.

## Primary-source architectures reviewed

### Temporal
Adopted principles: durable execution, replayable history, idempotency, failure isolation, resumable workflows, explicit retry policy with bounded backoff, and fencing so stale owners cannot commit after losing ownership.
ContentFlow mapping: `director_cycle_runs`, `director_state_transition_ledger`, `idempotency_key`, serialized Director cycle, retry classification/backoff, and fenced runner leases.

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

## ContentFlow V2 invariants
1. One active task -> one active builder run -> one worker owner.
2. Every active run has a valid fenced lease with `lease_token`, `lease_generation`, `runner_instance_id`, heartbeat and expiry.
3. Only the current lease owner may renew execution ownership.
4. A revoked or stale owner can never finalize or mutate backlog after losing ownership.
5. Backlog, builder run, worker queue and dispatch state must agree after every Director cycle.
6. A task with an active `claimed`, `running`, or `review_required` run is not dispatchable.
7. RARA is support-only and cannot abort Director control flow.
8. Director cycles are serialized by advisory lock.
9. Every new cycle and builder run carries workflow and trace identity.
10. State transitions are written to append-only ledgers.
11. Production parallelism is bounded before dispatch by Nexo lane capacity.
12. Scale-up is gated by recent clean cycles and failure rate.
13. Transient failures use bounded retry/backoff; non-transient quality/evidence failures require repair or strategy change.
14. Dispatcher cannot bypass cooldown or an open retry circuit.
15. New production runs must use `control_protocol=fenced-v2`; legacy writers cannot create an active run.
16. Completion is push-finalized by the execution owner; polling collectors are legacy-drain only.

## Fenced single-writer execution protocol
The production path is now:

`Director Core -> internal_builder_dispatch -> dispatch executor V2 -> runner V2 -> contentflow_finalize_run_v2`

Ownership semantics:
- `audit_builder_claim()` creates the active run with a unique lease token.
- `internal_builder_dispatch()` assigns worker/reviewer and dispatches only through the V2 executor.
- `contentflow-builder-agent-runner-v2` registers a unique runner instance and renews the fenced lease every 30 seconds while executing.
- `contentflow_builder_heartbeat_v2()` rejects the wrong token, a different runner instance, revoked ownership, or inactive runs.
- `contentflow_recover_orphan_claims()` revokes an expired fenced lease and increments the generation before requeue.
- `contentflow_finalize_run_v2()` atomically finalizes run/backlog/worker/dispatch only when the caller still owns the current lease.
- Late responses from an old owner become `superseded` and cannot mutate current task state.
- `contentflow-ranked-loop`, `contentflow-builder-worker`, and `contentflow-builder-sprint-dispatch` are retired from the production write path.
- Database guard `contentflow_guard_active_run_protocol()` rejects new active runs that do not use `fenced-v2`.

## Validation
A clean canary run (`builder_run_id=2037`) demonstrated the full protocol:
- active run created with `control_protocol=fenced-v2`
- unique lease token present
- heartbeat sequence advanced from 1 to 2 during execution
- stable `runner_instance_id`
- executor push-finalized the run without RARA or collector intervention
- dispatch moved to `collected`
- HTTP status 200
- final state `review_required`
- quality score 100
- lease revoked at finalization
- active state mismatches = 0
- pending dispatches older than the fenced lease window = 0

## Architectural rule
Do not add another orchestrator or writer path. New capabilities must plug into Director Core as deterministic stages, support services, middleware-style policy, or delegated agents. RARA supports the Director; it does not replace it. Any active execution outside the fenced single-writer protocol is invalid by design.
