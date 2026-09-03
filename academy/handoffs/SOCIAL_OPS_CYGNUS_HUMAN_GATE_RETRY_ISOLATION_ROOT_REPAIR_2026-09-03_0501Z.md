# Social Ops — Cygnus | Human-gate retry isolation root repair

Timestamp UTC: 2026-09-03 05:01Z
Canonical project: `agent-academy-platform-v1`
Canonical DAG: `academy-social-warmup-v3`
Publication gate: CLOSED
F10: HOLD

## Trigger for ChatGPT-level intervention

Director remained healthy and continued cycling every ~5 minutes, but `academy_social_rara_final_f06_f09_v3` stayed incorrectly blocked by a technical retry circuit from 2026-09-03 03:10:56Z through the intervention window (>10 minutes, in practice >1h45m). RARA had already produced a technically valid QA receipt and the only remaining condition was a human approval boundary: final Cygnus voice approval (`voice_final=false`, `publication_authorized=false`).

## Root cause

The retry classifier did not recognize final voice/publication authorization waits as human/external gates. `contentflow_classify_run_error()` therefore classified the RARA outcome as `unknown`; `contentflow_apply_retry_policy()` treated the non-retryable unknown outcome as a technical failure and opened a non-expiring circuit. The backlog state guard then prioritized the open retry circuit over the intended human-gate reason, producing `RETRY_CIRCUIT_OPEN` instead of the durable external wait.

## Structural correction

Applied migration `socialops_human_gate_retry_isolation_v1` and persisted source migration at:

`supabase/migrations/20260903050000_socialops_human_gate_retry_isolation_v1.sql`

Changes:

1. `contentflow_classify_run_error()` now classifies `voice not final`, `voice_final=false`, `publication_authorized=false`, explicit final-Cygnus-voice approval, owner/human approval, and `EXTERNAL_APPROVAL_WAIT` as `human_external_gate`.
2. `rara_classify_rejection()` now recognizes those same approval-boundary semantics as `owner_required` rather than a correctable quality defect.
3. `contentflow_apply_retry_policy()` now routes `human_external_gate` directly to a durable blocked external wait, deletes retry state, and emits `human_gate_isolated_from_retry`; it never schedules or opens a technical retry circuit for that condition.
4. Existing F06/F09 final-QA retry state was repaired in place without rerender, redispatch, upload, or publication.

## Evidence before repair

`academy_social_rara_final_f06_f09_v3`:
- status: `blocked`
- blocked_reason: `RETRY_CIRCUIT_OPEN`
- retry_state: `open`
- error_class: `unknown`
- attempt_count: `1`
- last_error: `Technical QA passed, but publication blocked due to voice not final (voice_final=false, publication_authorized=false).`

Verified upstream evidence remained intact:
- F06 evidence pack: `completed/runtime_proven`
- F09 evidence pack: `completed/runtime_proven`
- render v4: `completed/runtime_proven`
- render workflow: `33704282604`
- 16 rendered artifacts across 9:16, 4:5, 1:1, 16:9
- SHA-256/codecs/resolution verified
- publication authorization: false
- final voice: false

## Evidence after repair

`academy_social_rara_final_f06_f09_v3` now remains:
- status: `blocked`
- blocked_reason: `HUMAN_FINAL_CYGNUS_VOICE_APPROVAL_REQUIRED`
- workflow_state: `external_approval_wait`
- completion_phase: `external_prerequisite`
- next_eligible_at: `NULL`
- retry circuit: absent

Director cycle `13031` ran after the repair at 2026-09-03 05:00:52Z:
- status: `completed`
- dispatched: `0`
- workers_ready: `10`
- workers_running: `0`
- dispatchable: `0`
- active_state_mismatches: `0`
- warnings: none

This validates that the human gate survives a normal Director cycle and is not redispatched.

## F02–F09 canonical status

- F02: `AUTHENTIC_MEDIA_CAPTURE_REQUIRED` — external prerequisite, no retry circuit.
- F03: `AUTHENTIC_MEDIA_CAPTURE_REQUIRED` — external prerequisite, no retry circuit.
- F04: `AUTHENTIC_MEDIA_CAPTURE_REQUIRED` — external prerequisite, no retry circuit.
- F05: `AUTHENTIC_MEDIA_CAPTURE_REQUIRED` — external prerequisite, no retry circuit.
- F06: verified evidence pack `completed/runtime_proven`; render v4 evidence included; final QA waits only for final voice approval.
- F07: `AUTHENTIC_MEDIA_CAPTURE_REQUIRED` — external prerequisite, no retry circuit.
- F08: `AUTHENTIC_MEDIA_CAPTURE_REQUIRED` — external prerequisite, no retry circuit.
- F09: verified evidence pack `completed/runtime_proven`; render v4 evidence included; final QA waits only for final voice approval.

Legacy F02–F09 production rows have been retired/deferred by reconciliation and are not canonical work.

## Work reassignment / parallelism

No executable Social Ops task is currently being starved. No worker reassignment or GPU rerender is warranted. CPU/QA lanes remain free for other independent work. Shared Avatar GPU was not invoked in this repair.

## Guardrails preserved

- No upload performed.
- No publication performed.
- No media rerender performed.
- No evidence invented.
- No false `completed` state introduced.
- F10 remains HOLD.

## Next step

Wait for explicit human approval of the final Cygnus voice. Once a verified approval signal is persisted, the control-plane may release only the final F06/F09 approval path; it must not rerender or reopen retry circuits merely because the approval is pending.