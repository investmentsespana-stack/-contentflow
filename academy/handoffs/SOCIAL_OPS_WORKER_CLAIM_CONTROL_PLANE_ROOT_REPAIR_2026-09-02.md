# SOCIAL OPS — CYGNUS · CANONICAL DIRECTOR REPORT

Date: 2026-09-02
Scope: worker assignment/claim regression affecting F02-F09
Guardrails: no upload, no publication, F10 HOLD, no fabricated completion evidence.

## Executive state

The worker pool was not the root failure. Workers were READY and F02-F09 were dispatchable, but the primary auto-loop denied the ContentFlow Director core before dispatch. The regression is repaired at the admission/control-plane layer and validated with real builder claims.

## Root cause

1. The latest recovery certification remained structurally valid but crossed its 7-day freshness TTL. The auto-loop interpreted `receipt_stale` as a complete productive-mode denial even though a fresh verified daily recovery snapshot existed.
2. Retry admission counted all historical `contentflow_retry_state` open circuits globally. Normalization can touch old retry rows, making them appear recent and producing a false systemic `retry_budget_unhealthy` signal.
3. Because `contentflow-auto-loop` skipped `contentflow_director_core_cycle_auto`, handoffs remained READY without worker claims. The blocked-project watchdog intentionally skipped ContentFlow as owned by the primary loop, so no secondary path could dispatch them.

## Structural correction

- Deployed `contentflow-auto-loop` version 65, architecture `DURABLE_EXECUTION_CONTROL_LOOP_V11_RUN_CORRELATED_RETRY_HEALTH`.
- Recovery admission now accepts an otherwise-valid certification whose only defect is staleness when a fresh verified recovery snapshot proves rollback viability and deterministic migration replay.
- Recovery snapshot evidence self-refreshes from the canonical daily GitHub backup when the persisted snapshot is absent/stale; failure to retrieve/validate remains fail-closed.
- Retry health is now correlated to retry rows whose `last_run_id` belongs to actual builder runs created within the rolling 60-minute window. Normalization timestamps on historical circuits no longer poison global admission.
- Global retry shutdown requires a systemic sample (`retryStates >= 4`, `openCircuits >= 3`, open rate > 50%). Individual failed tasks remain isolated by their own state/circuit and RARA path.
- Runtime and GitHub source were reconciled. Source commits: `8f7359933c05987a9c98fd0b37e75df6fb9c3ae0` and `275523513a9e7e01316c74d69448ae1f9c9ec260`.

## Reproducible evidence

Pre-repair auto-loop: admission denied with `recovery_receipt_invalid` + `retry_budget_unhealthy`; 70 LLM-dispatchable tasks, 0 active runs, last ContentFlow Director cycle remained 2026-09-01 17:40 UTC.

First repaired run: auto-loop architecture V9 admitted productive mode, no blockers, 4 workers dispatched in Director cycle 12678. Builder runners accepted runs 7264-7267 with HTTP 202.

Verified Social Ops claims from that cycle:
- F02 -> builder run 7265 -> worker `doubao-seed-2-0-mini-260215`.
- F03 -> builder run 7266 -> worker `Qwen/Qwen3-Max`.
- F06 -> builder run 7267 -> worker claim created and review path reached.

After retry-signal hardening, V11 auto-loop admitted productive mode with `openCircuits=1`, `retryStates=2`, `retryOpenRate=0.5`, no blockers. Director cycle 12682 dispatched 2 workers. F09 received builder run 7269 and a real worker claim.

Recovery evidence used is the verified 2026-09-02 snapshot (`RECOVERY_SNAPSHOT_MIGRATION_REPLAY_CONTRACT_V2`), which records `passed=true`, rollback plan viable, deterministic replay viable, migration head `20260831145909`.

## Current F02-F09 state at report time

- F02: control-plane status `completed` via run 7265. Treat this as runtime completion only; do not infer publication or final audiovisual certification beyond stored evidence.
- F03: READY again after run 7266 failed for missing runtime-verifiable audiovisual evidence. Eligible for RARA/retry according to policy; do not fabricate the missing evidence.
- F04: READY.
- F05: READY.
- F06: BLOCKED / `REVIEW_PENDING`; RARA owns the next decision.
- F07: READY.
- F08: READY.
- F09: latest run 7269 reached a real worker claim and subsequently failed. Give Director/RARA the contractual correction/reassignment window before ChatGPT-level intervention.
- F10: HOLD unchanged.

## Tasks completed by this repair block

- Restored productive Director cycles for ContentFlow.
- Restored real worker claims rather than handoff-only release.
- Removed stale-certification false deadlock without weakening invalid recovery evidence checks.
- Removed historical retry-state pollution from global admission.
- Added self-refresh path for fresh daily recovery snapshot evidence.
- Persisted runtime repair in GitHub source.

## Work reassignable / parallel-safe

F03, F04, F05, F07 and F08 remain CPU/evidence/editing candidates when selected by the Director. F06 remains RARA review-owned. F09 remains failure-owned by Director/RARA until its correction window expires. Shared GPU work remains serialized under the certified Avatar contract and is not to be started merely because CPU claims resumed.

## Blockers

No worker-assignment/control-plane blocker remains in the validated V11 cycle. Content-level evidence failures remain task-local and must be repaired with genuine reproducible artifacts. No human publishing approval has been granted.

## Next step

Allow Director/RARA to process F03/F06/F09 task-local outcomes and continue assigning READY F04/F05/F07/F08 on normal cycles. If a non-human task remains stalled for more than 10 minutes without effective correction/reassignment, escalate only that task to ChatGPT-level diagnosis. Maintain 0 uploads / 0 publications for F02-F09 and keep F10 HOLD.
