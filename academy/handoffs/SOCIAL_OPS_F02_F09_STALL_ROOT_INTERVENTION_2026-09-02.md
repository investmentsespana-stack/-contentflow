# SOCIAL OPS — F02-F09 STALL ROOT INTERVENTION — 2026-09-02

Status: CHATGPT_INTERVENED / REASSIGNED / NOT_UPLOADED_NOT_PUBLISHED
Owner: Social Ops — Cygnus

## Evidence
- Canonical production release commit: `54c7add94925ab82614bd6bc25ea5c5157200af1`.
- Avatar AV reuse map commit: `3bdb931375f1711c7dd9f0db12eb3ce2353f1c8c`.
- `social-ops-handoff-autoreassign` run `33657390073` completed SUCCESS.
- In that run, `Extract Director reassignment actions and authoritative context`, PostgreSQL installation, and `Persist handoff with context and release work` all completed SUCCESS. `No reassignment section found` was skipped, confirming machine-readable reassignment was ingested.
- More than 10 minutes elapsed after successful release without any newer Social Ops production/evidence/master/QA commit for F02-F09. Later repository commits were unrelated Jarvis work.

## Root cause diagnosis
The release bridge is healthy; the stall is downstream of ingestion. The failure mode is therefore not handoff parsing or release. The Director accepted work but there is no repository-visible evidence that workers produced the first expected deliverables or that stalled items were re-reassigned. This is a control-plane consumption/progress-accountability gap.

## Structural correction
1. Split F02-F09 into independent evidence/CPU preparation lanes plus a serialized GPU lane; no worker may wait for GPU before completing script, captions, evidence manifest, provenance and edit timeline.
2. Require every lane to emit a repository-visible progress receipt before requesting GPU time. A receipt must state task, evidence source, completed artifact refs, blocker, next action and `NOT_UPLOADED_NOT_PUBLISHED`.
3. GPU requests are accepted only after authentic evidence and CPU-side package exist. Reuse certified Avatar GPU-06/GPU-07-compatible AV path; do not rebuild transport/lipsync.
4. If a lane cannot obtain its required authentic evidence, it must mark `BLOCKED_EVIDENCE_CAPTURE` and immediately return all independent work to the queue instead of remaining silently claimed.
5. RARA must evaluate completed masters fail-closed; inherited Avatar technical certification does not replace Cygnus final-master QA.

## Work completed by this intervention
- Verified the ingestion/release workflow succeeded end to end.
- Classified the current stall as downstream worker-consumption/progress-accountability rather than bridge failure.
- Re-issued F02-F09 as smaller parallel lanes with explicit progress-receipt requirements.
- Preserved F10 HOLD and publication/upload gates.

## Director reassignment
1. F02-EVIDENCE-CPU — immediately produce the authentic real-work-task evidence manifest, final master/short scripts, subtitles and edit timeline. If the real task cannot be captured with currently available owned evidence, emit `BLOCKED_EVIDENCE_CAPTURE` with the exact missing capture instead of waiting silently.
2. F03-EVIDENCE-CPU — in parallel, assemble sanitized Cygnus/Director operation evidence manifest, scripts, subtitles, provenance and edit timeline; remove secrets/private data. Emit a progress receipt even if final screen capture remains blocked.
3. F06-SYSTEM-EVIDENCE — immediately reuse verified Director/system-routing evidence already available in project records and build the non-GPU master/short timeline, captions and provenance. This lane must not wait for F02/F03.
4. F09-DIRECTOR-EVIDENCE — immediately reuse verified Director coordination evidence and repaired F09 visual proof already available; build master/short timeline, captions and provenance. This lane must not wait for F02/F03.
5. F04-EVIDENCE — prepare measurable before/after capture contract and all CPU-side production assets; prohibit fabricated timing.
6. F05-EVIDENCE — prepare source -> AI answer -> QA -> issue -> corrected-answer evidence package and CPU-side assets using authentic source material only.
7. F07-EVIDENCE — prepare authentic Cygnus learning-cycle evidence package and mobile-first edit plan.
8. F08-EVIDENCE — prepare sanitized OPC/process-analysis evidence package and business-opportunity edit plan.
9. GPU-LANE — after a lane has authentic evidence + CPU package, serialize professor/avatar segments through the certified Avatar GPU audiovisual path. Preserve Avatar source provenance and return generated artifact refs to the originating task.
10. RARA-FINAL — review each completed master for evidence authenticity, natural final voice, lipsync, artifacts, subtitles, mix, safe zones, branding, HIR/Deep Funnel alignment and provenance. Reject unsupported masters.
11. DIRECTOR-CONTROL — if any claimed lane has no progress receipt after a reasonable worker interval, release/reassign that lane rather than leaving it claimed. Keep independent lanes running while GPU is busy.

## Blockers
- Final renders still require authentic evidence for the concepts that cannot be proven from existing project records.
- Premium Cygnus voice remains a final-master QA decision; Piper is technical baseline only.
- No publication or upload approval exists.

## Next step
The Director must ingest this reassignment, demand first progress receipts from F02/F03/F06/F09 independently, then schedule only evidence-ready professor/avatar segments on the shared GPU lane. F04/F05/F07/F08 continue CPU/evidence work in parallel. F10 remains HOLD.
