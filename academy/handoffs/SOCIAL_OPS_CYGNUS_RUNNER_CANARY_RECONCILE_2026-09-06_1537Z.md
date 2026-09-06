# Social Ops — Cygnus · Canonical Director Report

Timestamp: 2026-09-06T15:37Z
Scope: F02-F09, especially F06/F09 Bella revoice
Publication authority: NONE. F02-F09 must not be uploaded or published without separate approval. F10 remains HOLD.

## Evidence observed

- avatar-platform commit `b5a65dd17bc32adbc4f327300a864adf8d2f4a0d` added a minimal `Runner Recovery Canary` using `ubuntu-24.04`.
- Canary run `34037172481` failed.
- avatar-platform commit `6b9f716efc924e2d40ec860523fa3c7de424622d` changed the canary to `ubuntu-slim`, paused failing scheduled workflows, preserved originals under `ops/workflow-backups/2026-09-06/`, and changed active `academy-social-revoice.yml` to a non-executing paused job (`if: false`) with workflow_dispatch only.
- Canary run `34037444420` also failed. Job `101497991892` completed with `steps=[]`, `runner_id=0`, empty runner name/group, label `ubuntu-slim`.

## Root cause classification

Current evidence supports `PRIVATE_REPO_GITHUB_HOSTED_RUNNER_ALLOCATION_UNAVAILABLE`, upstream of Bella executor logic. Switching from `ubuntu-24.04` to `ubuntu-slim` did not restore runner assignment. This is not evidence of a new Bella TTS/media/QA defect because no workflow step executed.

## Director/RARA autonomous action assessment

The Director/operator path made a reasonable structural correction before ChatGPT intervention: isolated the infrastructure with a minimal canary, stopped noisy scheduled retries, and preserved original workflows. That action is retained. No blind Bella rerun is authorized while the canary remains runner_id=0 / steps=[].

## Canonical Social Ops state

- F02/F03/F04/F05/F07/F08: remain human-source gated by `AUTHENTIC_MEDIA_CAPTURE_REQUIRED` unless newer reproducible control-plane evidence supersedes this report.
- F06/F09 certified real-video source task 16728: retain prior `completed/runtime_proven/runtime_verified=true`; this report does not alter that evidence.
- Bella revoice task 17568: BLOCKED / external prerequisite. New canonical blocker: `PRIVATE_REPO_GITHUB_HOSTED_RUNNER_ALLOCATION_UNAVAILABLE:canary_run=34037444420;job=101497991892;label=ubuntu-slim;runner_id=0;steps=0`.
- RARA final task 15653: remain blocked on `BELLA_REVOICE_RUNTIME_EVIDENCE_REQUIRED` until Bella produces reproducible runtime evidence.
- Multiformat 16724: remain dependency-gated.
- F10: HOLD.

## Correction / intervention performed in this block

No executor code was patched and no task was relaunched. The safe correction already applied autonomously (pause repetitive failing schedules + dedicated runner canary) was validated and retained. ChatGPT intervention was deliberately limited to canonical reconciliation/reporting because the remaining failure is an external runner-allocation prerequisite not repairable safely by changing Bella media logic.

## Safety / resource contract

- No F02-F09 upload or publication.
- No new GPU use.
- No rerender of certified F06/F09 source.
- Shared Avatar GPU serialization contract unchanged.
- CPU/evidence/edit/QA work may continue only where it does not require the unavailable GitHub-hosted runner or human media capture.

## Completed this block

1. Verified autonomous runner-recovery canary attempt.
2. Verified second canary on `ubuntu-slim` still fails before any step with runner_id=0.
3. Verified Bella active workflow is intentionally paused rather than blindly retried.
4. Reconciled the blocker without promoting any task to completed.

## Reassignable work

- Continue CPU-side editorial/evidence/QA preparation not dependent on missing authentic media.
- Continue inspection of GitHub Actions runner entitlement/allocation or prepare a certified CPU self-hosted runner path outside the shared Avatar GPU lane.
- Do not assign Bella execution until a minimal canary demonstrates an actually assigned runner and at least one executed step.

## Next step / release condition

Release 17568 for a single targeted execution only after a private-repo runner canary succeeds with an assigned runner (`runner_id != 0`) and executed steps. Then require the Bella executor to reproduce its full evidence contract (16 MP4 outputs, deterministic QA, hashes/codecs/resolutions/motion checks, callback, `publication_authorized=false`) before allowing RARA final 15653 to advance.
