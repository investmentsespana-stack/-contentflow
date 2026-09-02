# Social Ops — Cygnus · Media Capability Root Intervention

Date: 2026-09-02 20:55 UTC
Owner: Director / RARA / ChatGPT recovery level
Scope: F02-F09 only
Publication gate: CLOSED
Upload gate: CLOSED
F10: HOLD

## Trigger
F02-F09 had remained without material media-production progress for more than 10 minutes after the 20:10 UTC lane correction. The tasks were marked `evidence_producer`, but no task had a `contentflow_tool_execution_queue` row and `contentflow_tool_execution_capability_ready(...)` returned false for every F02-F09 item.

## Root cause
The control plane conflated two different evidence classes:

1. deterministic platform evidence that can be produced/verified by SQL, repository or runtime recipes; and
2. authentic audiovisual evidence requiring real screen/video capture, professional media production, subtitles, keyframes, SHA-256 provenance and audiovisual QA.

F02-F09 belong to class (2). The generic evidence producer has no legitimate ability to manufacture those assets. Therefore forcing queue rows or marking the capability ready would fabricate execution capacity and violate the no-invention guardrail.

The canonical F04-F09 capture queue explicitly requires authentic proof assets, real system/workflow states where applicable, source preservation, mobile-readable capture and final SHA-256 manifests. Generic stock may not serve as central proof. No upload or publication is authorized.

## Structural correction
Applied production migration `socialops_media_capture_capability_contract_v1` and persisted it in GitHub as:

`supabase/migrations/20260902205500_socialops_media_capture_capability_contract_v1.sql`

Git commit: `98f1fda7ba13f532a0331e049308ea5a6f1d3475`

The correction:

- adds explicit prerequisite `media_capture`;
- registers `media_capture` with `producer_available=false` and `verifier_available=false` until a real producer is certified;
- classifies video/subtitle/keyframe/SHA-256/screen-recording requirements as `media_capture` before generic runtime evidence rules;
- persists one media-capture evidence requirement for each F02-F09 task, correlated to its latest real builder run;
- retracts unsupported completed states where no verified media SHA/provenance evidence exists;
- prevents the generic deterministic evidence runner from claiming these tasks;
- retains the publication and upload gates closed.

## Validated post-state
All F02-F09 now have a persisted `media_capture` requirement and resolve to prerequisite `media_capture`.

`capability_ready=false` is now an intentional fail-closed state rather than an accidental routing gap.

F02 and F06 are explicitly blocked as `MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE`. F09 is also blocked on the same root prerequisite. F03/F04/F05/F07/F08 still have active `REVIEW_PENDING` state owned by RARA; their underlying media prerequisite is now explicit and cannot be mistaken for generic evidence work.

No synthetic master, fake screenshot, invented subtitles, fabricated keyframes or false SHA-256 evidence was created.

## Completed work
- Diagnosed missing queue/capability mismatch.
- Identified media-vs-deterministic-evidence contract error.
- Applied root database correction.
- Persisted migration in source control.
- Reconciled unsupported completion state without inventing replacement evidence.

## Reassignable safe parallel work
CPU/editorial/QA work that does not assert media completion can continue in parallel: script refinement, shot lists, captions drafts, provenance schema preparation, redaction plan, QA checklist and editorial packaging.

The shared Avatar GPU remains serialized and must only be invoked once a certified media producer/bridge owns the relevant F task and has authentic source assets.

## Current blocker
A certified Social Ops media-capture/production capability is not registered in the control plane. Until that capability exists, F02-F09 are not legitimately executable as full audiovisual production tasks. This is a capability gap, not a worker shortage.

## Next step for Director/RARA
Create and certify one bounded `media_capture` producer/bridge that can:

1. obtain or generate only authorized authentic source captures;
2. preserve originals and provenance;
3. render master/short media without publishing;
4. emit subtitles/keyframes/SHA-256 manifest;
5. run audiovisual QA;
6. persist evidence correlated to the F task/run;
7. serialize Avatar GPU use according to the certified Avatar contract;
8. set `producer_available=true` only after an end-to-end canary with reproducible evidence passes.

Do not reopen F02-F09 merely to send them back to an LLM worker. Reopen only when the media capability is real and certified.
