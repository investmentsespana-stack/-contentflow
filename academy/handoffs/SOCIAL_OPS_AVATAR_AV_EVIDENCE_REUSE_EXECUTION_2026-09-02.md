# SOCIAL OPS — AVATAR AV EVIDENCE REUSE EXECUTION — 2026-09-02

Status: EXECUTED / VERIFIED_REUSE_MAP / NOT_UPLOADED_NOT_PUBLISHED
Owner: Social Ops — Cygnus

## Scope
Execute the newly released Social Ops video block by resolving one immediately executable dependency shared by F02, F03, F06 and F09: determine which Avatar GPU audiovisual proofs are already verified and may be reused safely instead of rebuilding or re-certifying the same transport/lipsync stack from zero.

## Verified Avatar evidence
### GPU-06 progressive full E2E
Source commit: `31e1c222b2d053db0a8c8e10d9d4599b530007dd`
Canonical implementation: `ops/phase2-e2e-avatar.sh`
Verified contract encoded by the source:
- fresh Qwen text in same run;
- fresh Piper speech in same run;
- persistent MuseTalk 1.5 worker;
- progressive audio/video transport;
- run identity and commit SHA embedded into evidence;
- positive first-audio and first-video-frame metrics;
- at least 10 progressive video frames;
- transport presence required;
- output evidence written to `~/workspaces/avatar/data/evidence/phase2/full-e2e-latest.json`.

### GPU-06 same-run RARA verification
Source commit: `55a3994f138e61140eeec5dbe03f45350f758eb0`
Canonical workflow: `.github/workflows/phase2-e2e.yml`
RARA acceptance checks encoded in workflow:
- result PASS;
- exact GitHub run match;
- exact commit SHA match;
- evidence freshness < 15 minutes;
- first audio > 0;
- first video > 0;
- video frames >= 10;
- progressive transport present;
- fresh TTS same run;
- progressive transport same run.
Failure rejects with `RARA_GPU06_REJECTED`; success emits `RARA_GPU06_PASS`.
The workflow also confirms Nebius L40S before and after GPU-06.

### GPU-07 short endurance
Source commit: `55ab3ca11b2d6244058f6fe35c4124554dd60f8e`
Canonical script: `ops/gpu07-endurance.sh`
The endurance contract repeatedly invokes the certified full E2E path, requires PASS each cycle, same run identity/SHA, positive first-media metrics, >=10 frames and transport presence, and emits p50/p95 first-audio, first-video and total-E2E metrics. Acceptance emits `RARA_GPU07_ENDURANCE_PASS`.
This is Avatar endurance evidence; it must not be mislabeled as a duplicate Academy certification.

## Reuse decision for Cygnus
1. F02/F03/F06/F09 must reuse the already-certified Avatar transport/lipsync path when professor/avatar rendering is chosen.
2. Do not rebuild MuseTalk transport or shared GPU orchestration merely for Academy.
3. Piper is accepted only as the certified technical speech baseline. It is NOT automatically accepted as the premium Cygnus final voice.
4. Any final Cygnus voice substitution, changed avatar source, changed lipsync configuration, changed composition, denoise/upscale, or other media transformation that can affect perceived quality requires Cygnus RARA audiovisual QA on the produced master.
5. Evidence provenance must preserve Avatar source commit/run identity and distinguish inherited technical certification from Cygnus-specific final-master QA.

## Completed work
- Confirmed the Social Ops handoff release bridge now persisted and released machine-readable work successfully.
- Audited Avatar GPU-06 and GPU-07 certification sources directly.
- Converted those verified contracts into a Cygnus reuse map.
- Eliminated unnecessary duplicate certification work for transport/lipsync infrastructure.
- Preserved publication hold: 0 uploads, 0 publications.

## Blockers
- Authentic content evidence is still required per video: F02 real work task; F03 Cygnus/Director operation; F04 measurable before/after; F05 source/QA/correction; F07 learning cycle; F08 OPC/process evidence; F09 Director coordination evidence.
- Premium final voice still requires evaluation on the actual selected Cygnus voice; technical Piper baseline alone is insufficient.
- GPU jobs must respect Avatar shared-GPU serialization/concurrency contract.

## Director reassignment
1. F02 worker — proceed with authentic real-work evidence capture and CPU-side edit preparation immediately; when professor/avatar render is required, invoke the inherited GPU-06/GPU-07-compatible Avatar lane rather than rebuilding it.
2. F03 worker — proceed in parallel with sanitized Cygnus/Director operation capture; prepare edit/subtitle/provenance package while waiting for serialized GPU render.
3. F06 worker — prioritize existing verified system-routing evidence and build the non-GPU editorial/master timeline in parallel; reuse Avatar certified AV lane only for professor/avatar segments.
4. F09 worker — prioritize verified Director coordination evidence and repaired visual proof; prepare master/short timelines in parallel and reuse the certified AV lane for any professor/avatar footage.
5. F04/F05/F07/F08 workers — continue authentic evidence capture and CPU-side assembly concurrently; do not wait on GPU unless their approved creative specifically requires professor/avatar output.
6. RARA — for each final Cygnus master, distinguish inherited Avatar technical certification from Cygnus-specific audiovisual acceptance. Recheck final voice naturalness, lipsync, subtitle legibility, audio mix, artifacts, brand, Deep Funnel/HIR alignment and provenance.
7. Director — serialize only shared GPU audiovisual jobs; keep evidence capture, editing, captions, provenance, thumbnails/keyframes and QA preparation parallel. Maintain F10 HOLD and `NOT_UPLOADED_NOT_PUBLISHED` for all F02-F09.

## Next step
Collect the first authentic evidence packages for F02/F03/F06/F09, assemble CPU-side timelines in parallel, then feed only the professor/avatar segments through the certified Avatar GPU lane and issue Cygnus RARA receipts for final masters.
