# Social Ops — Cygnus · Canonical Director Report

## Block executed
Preproduction verification stall repair for Academy Social Warm-up DAG v3, focused on F06/F09 and preserving fail-closed media guards for F02-F09.

## Evidence observed
- Canonical v3 DAG is in `agent-academy-platform-v1`, ids 15644-15654.
- F06 run 7323 and F09 run 7324 remained `verification_required` for >30 minutes after RARA review queue entries were already `done`.
- Both runs were `review_approved=true` with quality 99/100 and 100/100 respectively, but their artifacts explicitly declared `NO_VERIFIED_EXTERNAL_EVIDENCE`, `NO_DEPENDENCIES`, and `NO_DIRECT_RUNTIME_SNAPSHOT`.
- Acceptance criteria require evidence-backed preproduction with exact provenance. Therefore these artifacts cannot safely promote to completed.
- F02/F03/F04/F05/F07/F08 remain blocked by `AUTHENTIC_MEDIA_CAPTURE_REQUIRED`; GPU task 15652 remains blocked by `EXTERNAL_GPU_EXECUTOR_REQUIRED`. No publication/upload action was taken.

## Root cause
The completion boundary had no deterministic reconciliation for the state: RARA review done + review approved + `verified_evidence_preproduction_only` + artifact explicitly declaring that no verified source evidence exists. This left the run indefinitely in `verification_required`.

A second collision was found after the first fix: `contentflow_backlog_state_guard` treated a blocked internal LLM artifact as retryable and reopened it to READY, even when `completion_phase='evidence_required'`.

## Structural correction
1. Added `contentflow_reconcile_preproduction_evidence_stall_v1` and a 5-minute cron reconciliation. It fail-closes only preproduction-only artifacts that explicitly contain all three no-evidence sentinels and whose RARA review is already done.
2. Such runs become failed with `VERIFIED_SOURCE_EVIDENCE_REQUIRED`; backlog completion phase becomes `evidence_required`.
3. Hardened `contentflow_backlog_state_guard` so `evidence_required` and explicit evidence-gap reasons cannot be converted back to READY merely because the artifact lane is internal.
4. Existing retry circuits remain authoritative; after normalization F06/F09 are safely blocked as `RETRY_CIRCUIT_OPEN` with `completion_phase=evidence_required` rather than being re-dispatched without new evidence.

## State after correction
- F02 capture gate: BLOCKED — AUTHENTIC_MEDIA_CAPTURE_REQUIRED.
- F03 capture gate: BLOCKED — AUTHENTIC_MEDIA_CAPTURE_REQUIRED.
- F04 capture gate: BLOCKED — AUTHENTIC_MEDIA_CAPTURE_REQUIRED.
- F05 capture gate: BLOCKED — AUTHENTIC_MEDIA_CAPTURE_REQUIRED.
- F06 verified evidence pack: BLOCKED — RETRY_CIRCUIT_OPEN; completion_phase=evidence_required; previous run 7323 closed with VERIFIED_SOURCE_EVIDENCE_REQUIRED.
- F07 capture gate: BLOCKED — AUTHENTIC_MEDIA_CAPTURE_REQUIRED.
- F08 capture gate: BLOCKED — AUTHENTIC_MEDIA_CAPTURE_REQUIRED.
- F09 verified evidence pack: BLOCKED — RETRY_CIRCUIT_OPEN; completion_phase=evidence_required; previous run 7324 closed with VERIFIED_SOURCE_EVIDENCE_REQUIRED.
- GPU render F06/F09: BLOCKED — EXTERNAL_GPU_EXECUTOR_REQUIRED.
- RARA final F06/F09: PLANNED, correctly dependency-gated; do not run until render/evidence prerequisites exist.
- Director control v3: COMPLETED, quality 100.

## Completed in this block
- Removed indefinite verification stall for F06/F09 without inventing evidence.
- Prevented state-guard reopening of missing-evidence preproduction tasks.
- Added recurring deterministic reconciliation for the same class of stall.

## Reassignable work
No F02-F09 media task is safely reassignable to an LLM at this moment. CPU editorial/QA may continue only where it does not claim authentic media or runtime proof. Media capture requires an authentic capture producer; F06/F09 render requires the external/certified GPU executor and must remain serialized.

## Blockers
- Authentic media capture capability/source evidence for F02/F03/F04/F05/F07/F08.
- Verified source evidence for F06/F09 before their preproduction packs can be regenerated.
- External/certified GPU executor for render task 15652.

## Next step
Director/RARA should not retry F06/F09 until new verified source evidence is persisted. Once evidence exists, close only the affected retry circuits, regenerate the corresponding pack, then serialize GPU render through the certified Avatar path and run final RARA audiovisual QA.

## Guardrails
0 uploads. 0 publications. F10 remains HOLD. No completed status was created without reproducible support.
