# Social Ops — Cygnus · Control-plane media lane root repair

Date: 2026-09-02 20:12Z
Owner: Director / RARA / Social Ops — Cygnus
Publication gate: CLOSED
Upload gate: CLOSED
F10: HOLD

## Evidence observed

- F02 was marked `completed` with quality 100, but its stored result explicitly declared `NO_VERIFIED_EXTERNAL_EVIDENCE` while also claiming master/short/subtitles/SHA deliverables. No matching verified row exists in `director_external_evidence` for F02–F09.
- F03 run 7278, F04 run 7270, F05 run 7271, F07 run 7273 and F08 run 7274 remain in the durable RARA review queue; RARA recovered stale claims and is actively reclaiming F03/F05 at 20:05Z. These were not forcibly reassigned while RARA was progressing.
- F09 run 7279 failed at 19:07:50Z because verified subtitles, keyframes and SHA-256 were absent. By 19:25:51Z the task was `ready` while `contentflow_retry_state` remained `open`, leaving it undispatchable for >40 minutes.
- Runtime ledger for F09 recorded `retry_blocked` from `director_retry_policy`; this was not a worker-capacity problem.

## Root cause

Two contracts conflicted:

1. Social Ops media-producing handoffs were routed as `llm_artifact`, despite requiring real binary/media evidence (video/render/master + subtitles/keyframes/SHA).
2. `contentflow_backlog_state_guard()` could convert a generic blocked internal-artifact task back to `READY` even when retry had already opened its circuit. This created the invalid state `READY + circuit OPEN` and allowed recent task-local failures to contaminate global retry-health admission.

## Structural corrections applied

### 1. Media execution-lane guard

Migration: `20260902201005_socialops_media_execution_lane_guard_v1`
Git commit: `bafe28ec71dad6da98c345391b333e12fd3ae53b`

- Added `contentflow_external_media_lane_guard_v1()` and trigger.
- External handoffs that require real video/render/master plus subtitles/keyframes/SHA/evidence are forced to `evidence_producer` rather than `llm_artifact`.
- F02–F09 were migrated to `evidence_producer`.
- F02 false completion was reopened as `blocked / EVIDENCE_INTEGRITY_MISMATCH_NO_VERIFIED_MEDIA`.
- F09 was moved to `blocked / EVIDENCE_PRODUCER_REQUIRED_MEDIA_ARTIFACTS`; its stale retry circuit was closed.

### 2. Retry state ordering / RARA safe requeue

Migration: `20260902201137_retry_circuit_state_guard_ordering_v2`
Git commit: `36b5c2b452d5b24d83a818cb1bb51162b25d6157`

- `contentflow_backlog_state_guard()` now preserves `RETRY_CIRCUIT_OPEN` instead of converting a blocked task back to READY.
- `rara_safe_requeue_failed_task()` now closes the retry circuit before setting backlog state to READY, so a legitimate RARA repair can pass the state guard atomically.
- Existing `READY + OPEN` inconsistencies were converted to `blocked / RETRY_CIRCUIT_OPEN`.

## State after repair

- F02: BLOCKED, evidence_producer, integrity mismatch; no verified media evidence.
- F03: BLOCKED / REVIEW_PENDING, evidence_producer; RARA review active/recovered.
- F04: BLOCKED / REVIEW_PENDING, evidence_producer; pending RARA review.
- F05: BLOCKED / REVIEW_PENDING, evidence_producer; RARA review active/recovered.
- F06: COMPLETED as a truthful verifiable-block outcome; its result states no real media artifacts were produced because evidence/runtime was absent. Execution lane is now evidence_producer for future continuation.
- F07: BLOCKED / REVIEW_PENDING, evidence_producer.
- F08: BLOCKED / REVIEW_PENDING, evidence_producer.
- F09: BLOCKED / EVIDENCE_PRODUCER_REQUIRED_MEDIA_ARTIFACTS, evidence_producer; retry circuit CLOSED.

## Current blockers

The media evidence producer capability check for F02/F09 is currently false. Therefore these tasks must not be repeatedly dispatched to an LLM and must not be called completed as produced videos until real artifacts are generated and verified.

At 20:10Z the primary auto-loop entered `support_only` because three recent, unrelated external-handoff retry circuits caused `retry_budget_unhealthy`; this condition had not yet exceeded the 10-minute intervention threshold at the time of this report. Director/RARA retain first opportunity to clear/reclassify those task-local failures. If the global admission remains blocked for >10 minutes without effective self-repair, ChatGPT intervention is warranted on retry-health scoping.

## Completed work

- Root classification defect repaired.
- Retry state/backlog ordering defect repaired.
- False F02 completion revoked.
- F09 impossible READY+OPEN state removed.
- Future matching Social Ops media work prevented from entering the LLM-only lane.
- No upload and no publication performed.

## Reassignable work

CPU/evidence preparation, subtitles, keyframe extraction, hashing, QA receipts and provenance can run in parallel once a real evidence producer/renderer is available. Shared Avatar GPU work remains serialized under the certified Avatar contract.

## Next step

Director/RARA should finish the already-claimed reviews without duplicate intervention, then route F02/F09 and any rejected F03–F08 items to a real evidence producer/renderer. Do not mark produced/completed without reproducible binary artifacts and verified evidence. Keep F10 on HOLD and publication/upload gates CLOSED.
