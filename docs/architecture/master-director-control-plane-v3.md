# Master Director Control Plane V3

## Purpose
Close the remaining autonomy gap by turning Director Core from a cycle executor into a durable control plane that continuously reconciles desired state against observed runtime state.

## Architecture sources and adopted patterns

- **Kubernetes controllers/operators:** desired-state reconciliation, idempotent control loops, eventual convergence, explicit health invariants.
- **Temporal:** durable execution, resumability, bounded retries, idempotency and failure isolation.
- **Conductor-style workflow control:** explicit task states, timeout/retry policy, failure classification and compensation/recovery paths.
- **Existing ContentFlow V2:** atomic claims, leases/heartbeats, serialized Director cycles, event ledger, trace IDs/spans, RARA support boundary, evidence-first completion and Nexo lane capacity gates.

## V3 principle
Do not add a second orchestrator. All new capabilities plug into Director Core as deterministic reconciliation stages, policy, support services or delegated agents.

## Implemented runtime components

### `director_control_policy`
Declarative desired operating state for each project. Initial ContentFlow policy:
- desired running workers: 6
- minimum ready buffer: 4
- no-progress SLO: 15 minutes
- maximum human-help incidents: 0
- maximum active state mismatches: 0

### `contentflow_master_reconcile(project_key)`
Service-role-only reconciler. Each pass performs:
1. orphan-claim recovery
2. runtime-state reconciliation
3. expired-lease recovery
4. review-gate reconciliation
5. retry-policy reconciliation
6. RARA incident detection
7. known-repair execution
8. obsolete/transient incident cleanup
9. autonomy-SLO enforcement
10. resilience invariant self-test

### `contentflow_enforce_autonomy_slo(project_key)`
Compares desired versus actual runtime state. It creates a repair incident when ready workers and dispatchable work exist but accepted progress stalls beyond policy. Human-help count is also enforced as an autonomy SLO.

### `contentflow_resilience_self_test(project_key)`
Persists evidence for critical invariants:
- no duplicate active owner
- no expired active lease
- no orphan running worker
- no active backlog/run/worker mismatch
- no unresolved human-help boundary breach

### `director_resilience_checks`
Durable evidence ledger for invariant probes with expected/observed values and trace correlation.

### Auto-loop V26
`contentflow-auto-loop` now executes Master Director reconciliation both before and after the existing Director Core cycle. RARA remains asynchronous support and does not replace Director authority.

## Transient-capacity correction
Nexo capacity/rate-limit conditions are classified as transient capacity failures rather than generic builder failures. Obsolete `needs_help` incidents caused solely by transient capacity are automatically resolved when the task has returned to an actionable lifecycle state.

## Acceptance gate for Master Director 100%
The Director is not declared fully autonomous merely because implementation exists. Release requires repeated real cycles demonstrating:
- zero duplicate active ownership
- zero expired live leases
- zero orphan running workers
- zero active state mismatches
- zero false human-help escalations for transient capacity
- progress under available capacity without human intervention
- successful autonomous recovery from induced failures
- durable evidence for every recovery and completion boundary

## Status
V3 is deployed to the Supabase runtime. Initial invariant probes passed ownership, lease, worker/run consistency and state-consistency checks. Human-help boundary identified two legacy false escalations caused by Nexo capacity; classification and cleanup logic were hardened to prevent recurrence. Final certification remains evidence-driven across repeated runtime cycles.