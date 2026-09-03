# Social Ops — Cygnus · F06/F09 QA evidence bridge root repair

Timestamp UTC: 2026-09-03 03:09Z
Scope: control-plane + canonical Social Ops warm-up DAG v3. No upload/publication authorized. F10 remains HOLD.

## Evidence observed
- Canonical render task `academy_social_media_render_f06_f09_v4` (backlog id 15781) is `completed`, `runtime_verified=true`, `completion_phase=runtime_proven`.
- Persisted runtime evidence contains 16 media artifacts covering 9x16, 4x5, 1x1 and 16x9 profiles, H.264/AAC technical metadata, subtitles, keyframes and SHA-256 hashes; `workflow_run_id=33704282604`, `commit_sha=262e2bdf79a0cc3d55d729b9e273b63d0ed60c8f`, `github_oidc_verified=true`, `publication_authorized=false`, `voice_final=false`.
- RARA final task `academy_social_rara_final_f06_f09_v3` failed run 7326 at 2026-09-03 01:46:34Z claiming no verified render-output evidence, despite the dependency evidence above being present in the control-plane.
- The stall exceeded the 10-minute intervention threshold.

## Root cause
`internal_builder_dispatch()` supplied dependency `result` text to downstream LLM workers but did not expose persisted `runtime_evidence`. The verified media evidence therefore existed in the database but was invisible to RARA final. This was an evidence-context bridge defect, not a render/GPU defect.

A second state-machine issue appeared after technical QA: the backlog state guard treated an explicit human approval block on an internal LLM artifact as a generic internal block and automatically reopened it as READY.

## Structural corrections
1. Migration `20260903030400_dependency_runtime_evidence_context_v2.sql` changes `contentflow_verified_external_evidence_context()` so downstream tasks receive verified runtime evidence from completed, runtime-verified dependencies. This is generic and reusable; it does not fabricate evidence.
2. The affected RARA task was the only task requeued. No render was repeated and no GPU work was relaunched.
3. RARA run 7327 received the persisted dependency evidence and confirmed provenance, workflow run, commit, codecs, resolutions, subtitles/keyframes and SHA-256 metadata.
4. RARA 7327 correctly did not release publication: `voice_final=false` and `publication_authorized=false` remain gates. The task was reconciled to `HUMAN_FINAL_CYGNUS_VOICE_APPROVAL_REQUIRED`, not completed.
5. Migration `20260903030800_state_guard_human_gate_v1.sql` makes `HUMAN_*` blockers first-class fail-closed states so the state guard cannot reopen them as executable internal-artifact retries.

## Post-state
- F06 evidence pack: `completed/runtime_proven`.
- F09 evidence pack: `completed/runtime_proven`.
- F06/F09 render v4: `completed/runtime_proven`; no rerender required.
- F06/F09 RARA final: `blocked`, `completion_phase=external_prerequisite`, `workflow_state=human_gate`, blocker `HUMAN_FINAL_CYGNUS_VOICE_APPROVAL_REQUIRED`.
- F02/F03/F04/F05/F07/F08 capture gates remain `blocked/AUTHENTIC_MEDIA_CAPTURE_REQUIRED`; no LLM substitution permitted.
- Publication/upload gate remains CLOSED. F10 remains HOLD.

## Completed this block
- Diagnosed evidence-context root cause.
- Added reusable verified dependency runtime-evidence propagation.
- Requeued only RARA final and validated run 7327 consumed real persisted evidence.
- Prevented human approval gates from being auto-reopened.
- No media publication, upload, destructive mutation or duplicate GPU render occurred.

## Reassignable work
CPU/evidence/editing work for lanes that have authentic evidence may continue in parallel. F02/F03/F04/F05/F07/F08 require authentic capture before downstream production. F06/F09 require a separately approved final Cygnus voice decision before final approval; publication still requires separate owner approval.

## Next step
Director/RARA should keep F06/F09 fail-closed at the human voice gate and must not retry or rerender until new approved voice evidence exists. Continue independent CPU/evidence/QA work elsewhere. Shared Avatar GPU remains serialized and should not be invoked for F06/F09 again unless a newly approved voice requires a new render under the certified GPU contract.
