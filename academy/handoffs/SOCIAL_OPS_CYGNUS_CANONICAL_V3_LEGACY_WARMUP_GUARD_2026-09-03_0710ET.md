# Social Ops — Cygnus canonical v3 legacy warmup guard

Date: 2026-09-03 07:10 ET
Scope: Social Ops / Cygnus F02-F09 control-plane and handoff reconciliation
Publication/upload gate: CLOSED
F10: HOLD

## Executive state

No new active F02-F09 production branch was created in this review window. The active canonical DAG remains `academy-social-warmup-v3`.

Canonical state observed after repair:
- F02 `academy_social_f02_capture_gate_v3`: BLOCKED / `AUTHENTIC_MEDIA_CAPTURE_REQUIRED`.
- F03 `academy_social_f03_capture_gate_v3`: BLOCKED / `AUTHENTIC_MEDIA_CAPTURE_REQUIRED`.
- F04 `academy_social_f04_capture_gate_v3`: BLOCKED / `AUTHENTIC_MEDIA_CAPTURE_REQUIRED`.
- F05 `academy_social_f05_capture_gate_v3`: BLOCKED / `AUTHENTIC_MEDIA_CAPTURE_REQUIRED`.
- F06 `academy_social_f06_verified_evidence_pack_v3`: COMPLETED / `runtime_proven`, `runtime_verified=true`.
- F07 `academy_social_f07_capture_gate_v3`: BLOCKED / `AUTHENTIC_MEDIA_CAPTURE_REQUIRED`.
- F08 `academy_social_f08_capture_gate_v3`: BLOCKED / `AUTHENTIC_MEDIA_CAPTURE_REQUIRED`.
- F09 `academy_social_f09_verified_evidence_pack_v3`: COMPLETED / `runtime_proven`, `runtime_verified=true`.
- F06/F09 render v4 `academy_social_media_render_f06_f09_v4`: COMPLETED / `runtime_proven`, `runtime_verified=true`.
- Final RARA F06/F09 `academy_social_rara_final_f06_f09_v3`: BLOCKED / `HUMAN_FINAL_CYGNUS_VOICE_APPROVAL_REQUIRED`.

No GPU rerender was requested. No upload or publication was performed.

## Detected stall

Legacy task `academy_today_warmup_rara_qa_v1` (backlog id 15595) remained `READY` with an OPEN retry circuit from builder run 7262 even though it had been semantically replaced by the canonical v3 Social Ops DAG. The failed legacy run had correctly refused to invent F02-F09 media evidence, but the task itself had never been durably marked superseded.

This exceeded the autonomous-repair window by many hours. Director/RARA had already created and advanced the v3 DAG, including runtime-proven F06/F09 evidence and render v4, so another retry of the old QA branch would have been duplicate/stale work.

## Root cause

Supersession was represented on later handoff branches, but the older `academy_today_warmup_%` task family in `agent-academy-platform-v1` had no durable guard tying it to the existence of the canonical v3 DAG. Consequently, generic retry/state reconciliation could continue to regard legacy tasks as eligible work.

## Structural correction

Applied Supabase migration:
`socialops_canonical_v3_legacy_warmup_guard`

The migration installs a narrow BEFORE INSERT/UPDATE guard on `contentflow_build_backlog`:
- applies only to project `agent-academy-platform-v1`;
- applies only to task keys matching `academy_today_warmup_%`;
- activates only while canonical sentinel `academy_social_f02_capture_gate_v3` exists and is not superseded;
- forces the legacy branch to `deferred / superseded`;
- sets blocker `SUPERSEDED_BY_ACADEMY_SOCIAL_WARMUP_DAG_V3`;
- clears `next_eligible_at`;
- removes retry-state rows for the superseded legacy branch.

This prevents future state normalizers or retry reconciliation from reopening the obsolete branch while the canonical v3 DAG is active.

Repository migration:
`supabase/migrations/20260903110800_socialops_canonical_v3_legacy_warmup_guard.sql`
Commit: `8a33ef5b9eeef1cd526cf6be2f3c5a78c1df5f16`

## Verification evidence

Post-migration task 15595:
- status: `deferred`
- completion_phase: `superseded`
- workflow_state: `superseded`
- blocked_reason: `SUPERSEDED_BY_ACADEMY_SOCIAL_WARMUP_DAG_V3`
- next_eligible_at: NULL
- retry rows: 0

Reopen-canary executed by deliberately attempting to write task 15595 back to `ready / artifact_pending`. The BEFORE trigger intercepted the write and returned the task unchanged as `deferred / superseded`, proving the repair is durable rather than a one-time data patch.

Supabase security advisor was run after DDL. The new guard is `SECURITY INVOKER` and generated no new SECURITY DEFINER exposure warning. Existing project-wide advisor warnings are pre-existing and outside this Social Ops repair block.

## Work completed

- Detected stale executable legacy RARA QA branch.
- Confirmed canonical v3 already supersedes that branch semantically.
- Installed durable legacy-warmup supersession guard.
- Retired the stale QA task without marking it completed.
- Cleared only its obsolete retry circuit.
- Validated anti-reopen behavior with a reproducible write canary.
- Revalidated canonical F02-F09 state.

## Reassignable work

No additional CPU/GPU/QA lane should be reassigned from the retired legacy branch.

Safe parallel work remains whatever does not require missing authentic media capture. F02/F03/F04/F05/F07/F08 remain fail-closed until authentic capture evidence exists. F06/F09 remain technically rendered and evidence-backed; only the explicit final Cygnus voice approval gate remains.

## Blockers

- F02/F03/F04/F05/F07/F08: `AUTHENTIC_MEDIA_CAPTURE_REQUIRED`.
- F06/F09 final acceptance: `HUMAN_FINAL_CYGNUS_VOICE_APPROVAL_REQUIRED`.
- Publication/upload authorization: CLOSED.
- F10: HOLD.

## Next step for Director

Continue monitoring only the canonical v3 DAG. Do not redispatch any `academy_today_warmup_%` branch while v3 remains active. If authentic capture evidence arrives, release only the corresponding F02/F03/F04/F05/F07/F08 lane. For F06/F09, wait for the separate verified final-voice approval signal; do not rerender or publish merely to satisfy the old QA branch.
