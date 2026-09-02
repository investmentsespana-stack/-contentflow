# Social Ops — Cygnus · Control-plane canonical report

Timestamp UTC: 2026-09-02 19:08Z
Scope: F02-F09 only. No upload/publish authorization. F10 remains HOLD.

## Evidence observed before intervention

- F02 completed: builder_run_id=7265, quality_score=100.
- F06 completed: builder_run_id=7267, quality_score=100.
- F03 had failed run 7266, backlog was requeued to READY, but retry_state remained circuit_state=open with no circuit_open_until and no next_retry_at. It remained undispatchable for >10 minutes.
- F09 had failed run 7269, backlog was requeued to READY, but retry_state remained circuit_state=open with no circuit_open_until and no next_retry_at. It remained undispatchable for >10 minutes.
- F04/F05/F07/F08 were in REVIEW_PENDING. RARA had begun active recovery/claiming, so they were not force-modified.

## Root cause

`public.rara_safe_requeue_failed_task()` changed a failed/blocked task back to backlog status READY but did not close the corresponding `contentflow_retry_state` circuit. `contentflow_dispatchable_count()` and the Director dispatcher exclude any task whose retry circuit is open. Therefore the UI/control-plane could show READY while the task was structurally undispatchable.

This was a state-contract split between backlog readiness and retry admission, not a lack of workers.

## Structural correction

Applied migration `rara_requeue_closes_retry_circuit_v2` in Supabase and persisted source migration at:

`supabase/migrations/20260902190700_rara_requeue_closes_retry_circuit_v2.sql`

Git commit: `8ca6a6dd9ab9882e7882743c4af8a12e6854bde1`

New invariant for a successful RARA safe requeue:

1. backlog -> READY
2. selected_model -> NULL
3. blocked_reason -> NULL
4. next_eligible_at -> now()
5. retry_state.circuit_state -> closed
6. circuit_open_until -> NULL
7. next_retry_at -> now()

For the two already stranded tasks, F03 and F09, the retry state was cleared through the canonical `contentflow_clear_retry_after_repair()` function and the normal auto-loop was invoked. No direct worker assignment was forged.

## Validation after correction

Director cycle 12701 completed with dispatched=2, workers_running=2, active_state_mismatches=0.

The two repaired tasks were immediately claimed through the normal dispatcher:

- F03 -> builder_run_id=7278 -> worker `deepseek-ai/DeepSeek-V3.2-Exp` -> progressed to REVIEW_PENDING with quality_score=100.
- F09 -> builder_run_id=7279 -> worker `doubao-seed-2-0-mini-260215` -> executed and failed again because verified subtitles, keyframes and SHA-256 evidence were still missing. This is a task/evidence failure, not a dispatch failure; the new failure is fresh and remains inside the Director/RARA self-repair window.

RARA review activity also resumed/continued:

- F04 run 7270: review claim active.
- F05 run 7271: review claim active.
- F07 run 7273: review claim active.
- F08 run 7274: review claim active.

## Current canonical state

- F02: COMPLETED in runtime control-plane, run 7265, quality 100.
- F03: REVIEW_PENDING after successful relaunch, run 7278, quality 100.
- F04: REVIEW_PENDING, RARA claim active, run 7270.
- F05: REVIEW_PENDING, RARA claim active, run 7271.
- F06: COMPLETED in runtime control-plane, run 7267, quality 100.
- F07: REVIEW_PENDING, RARA claim active, run 7273.
- F08: REVIEW_PENDING, RARA claim active, run 7274.
- F09: FAILED on fresh run 7279 due missing verified audiovisual evidence; give Director/RARA normal recovery window before ChatGPT-level intervention.

Runtime COMPLETED does not authorize publication and does not substitute for final audiovisual evidence if the task contract requires it.

## Blockers

- F09 requires real, verified subtitles/keyframes/SHA-256 evidence tied to the new execution. Do not invent these artifacts.
- F03/F04/F05/F07/F08 are under active review/recovery and should not be force-reassigned while claims are fresh.

## Reassignable work

No forced reassignment is appropriate at this instant. F09 may become reassignable only if Director/RARA fail to repair/requeue it within the configured >10 minute non-human failure window. Independent CPU/evidence/editing/QA work remains parallel-safe. Shared GPU work must remain serialized under the Avatar contract.

## Guardrails

- 0 uploads.
- 0 publications.
- F10 HOLD.
- No fabricated evidence.
- No direct manual worker claim was created; validation used the canonical Director dispatcher.

## Next step

Observe Director/RARA handling of fresh F09 failure and completion of active review claims. If any remains without material progress >10 minutes after its latest failure/claim recovery, intervene only on the affected task and validate via a real builder_run/worker claim.
