# ContentFlow clean recovery baseline — 2026-08-16

Project: ContentFlow AI V0.3
Supabase project: koqpyfvnprmirqviafzq
Purpose: recovery baseline after architectural sanitation.

## Canonical runtime path

1. `contentflow-auto-loop` v27
2. `contentflow_master_reconcile()`
3. `contentflow_director_core_cycle_auto()` with fixed parallelism 2
4. `internal_builder_dispatch()`
5. `contentflow-dispatch-executor-v2` v1
6. `contentflow-builder-agent-runner-v2` v5
7. `contentflow_finalize_run_v2()`
8. RARA review path: `contentflow-rara` v8 -> `rara_apply_review_decision_v2()`

## Fixed operating policy

- Maximum running agents: 2
- Automatic capacity scaling: disabled
- `director_canary_policy.bootstrap_parallelism = 2`
- `director_canary_policy.stable_parallelism = 2`
- `director_control_policy.desired_running = 2`
- Only active scheduler: `contentflow_autonomous_director_5m`
- Legacy capacity autoscale cron removed

## Legacy writers quarantined

Execution revoked from PUBLIC/anon/authenticated/service_role for:

- `internal_builder_finalize(bigint,text,text,numeric,numeric,text,text,boolean)`
- `internal_builder_approve_review(bigint)`
- `contentflow_builder_heartbeat(bigint,integer)`
- `internal_builder_recover_stale_claims(integer)`
- `rara_apply_review_decision(bigint,boolean,text)`

Legacy backlog review trigger `trg_backlog_review_gate` removed. Canonical completion protection remains through runtime-evidence and builder review gates.

## Dependency graph sanitation

- Self-dependencies forbidden.
- Duplicate dependencies forbidden.
- `contentflow_sanitize_dependency_graph()` runs from master reconcile.
- Dependency guard trigger installed.

## Runtime verification after sanitation

Director cycle #100:

- status: completed
- dispatched: 2
- workers running: 2
- workers ready: 8
- active state mismatches: 0
- warnings: 0
- capacity respected: true

This baseline is the approved recovery point after sanitation. Do not restore legacy writer privileges or the removed autoscaling cron without an explicit architecture migration and regression test.
