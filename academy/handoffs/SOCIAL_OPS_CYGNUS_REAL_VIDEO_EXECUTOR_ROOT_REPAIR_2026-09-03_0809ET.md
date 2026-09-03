# Social Ops — Cygnus · Canonical intervention report

Date: 2026-09-03 08:09 ET
Scope: Social Ops F02-F09 only. Publication remains closed. F10 remains HOLD.

## Trigger for ChatGPT-level intervention

Director received a reasonable autonomous-recovery window after the new real-video tasks were created at 2026-09-03 11:45:23Z. Academy Director cycles at 11:45:54Z, 11:50:52Z, 11:55:59Z and 12:00:52Z all completed cleanly with `dispatched=0`, `dispatchable=0`, no warnings/errors and no active state mismatches. The affected Social Ops tasks therefore remained without material recovery for >10 minutes.

Affected tasks:
- 16722 `academy_social_warmup_real_video_f02_f05_f07_f08_v1`
- 16728 `academy_social_warmup_real_video_f06_f09_v1`

Both had been placed in `blocked / STATE_GUARD_BLOCKED_UNSPECIFIED`, despite their dependency `academy_gpu_connectivity_canary_20260903_v1` (16729) already being `completed/runtime_proven` with GitHub run 33751339074 and an NVIDIA L40S connectivity canary.

## Root cause

1. The new `tool_executor` tasks were created without complete executable routing. In particular 16728 had no `execution_recipe`, while the state guard did not recognize a valid external tool recipe as an execution-in-progress state.
2. The existing F06/F09 GitHub media bridge was hard-wired to the older completed task `academy_social_media_render_f06_f09_v4`.
3. The existing renderer generated PIL image cards and looped static PNGs with fades. That architecture cannot satisfy the new acceptance contract `REAL_VIDEO_NOT_SLIDES` and would have recreated the rejected slide-style output if reused unchanged.
4. F02/F03/F04/F05/F07/F08 genuinely require authentic capture. Their lack of captured source evidence is not safely repairable by synthesizing media.

## Structural corrections executed

### F02/F03/F04/F05/F07/F08
Task 16722 was normalized fail-closed to:
- status: `blocked`
- completion_phase: `external_prerequisite`
- blocked_reason: `AUTHENTIC_MEDIA_CAPTURE_REQUIRED`
- next_eligible_at: null

No fabricated capture was created and no LLM substitute was accepted.

### F06/F09 executable route
Task 16728 received a durable external execution contract:
- handler: `external_github_actions_oidc`
- repo: `investmentsespana-stack/avatar-platform`
- workflow: `academy-social-warmup-render.yml`
- `gpu_required=false`
- `runtime_required=true`
- `video_definition=REAL_VIDEO_NOT_SLIDES`
- `publication_authorized=false`

The Supabase edge bridge `academy-social-warmup-github-bridge` was upgraded to v3. It now targets task 16728 and will reject completion unless all 16 expected social-format MP4 artifacts pass dimensions, SHA-256 and explicit real-motion QA (`motion_verified=true`, `static_slide_only=false`, `video_definition=REAL_VIDEO_NOT_SLIDES`). GitHub OIDC remains required for completion callbacks.

The Avatar workflow was structurally upgraded in commit:
`ebc689690ca865100b1528733e2c9a047372f2bf`

It now applies continuous time-based motion treatment after evidence-sequence rendering, re-hashes the final outputs, extracts separated frames from every MP4 to verify visual change reproducibly, and only then returns evidence through the OIDC bridge. This workflow uses GitHub CPU, not the shared Nebius GPU, so the Avatar GPU serialization contract is untouched.

## Control-plane state-machine repair

A canary relaunch proved that the control-plane immediately converted 16728 back to `STATE_GUARD_BLOCKED_UNSPECIFIED` even while GitHub Actions was already progressing. The durable state guard was therefore repaired to recognize `tool_executor + execution_recipe.handler` as external execution. Such work is now represented as:
`blocked / EXTERNAL_EXECUTION_IN_PROGRESS / next_eligible_at=null`
instead of a generic unexplained block.

Persisted migration:
`supabase/migrations/20260903120700_tool_executor_external_execution_state_guard_v1.sql`
commit `cbb42a5a5d33a65844eed11781e5326d232ef9de`.

Canary result after trigger: task 16728 became `blocked / EXTERNAL_EXECUTION_IN_PROGRESS`, confirming the generic-state regression is removed for this class of tasks.

## Evidence that work resumed

GitHub Actions run `33753261598` started from commit `ebc689690ca865100b1528733e2c9a047372f2bf`.
Latest observed steps:
- checkout: PASS
- deterministic sanitized evidence fetch: PASS
- media runtime install: PASS
- F06/F09 evidence-sequence rendering: IN PROGRESS
- continuous motion treatment: pending behind render
- deterministic real-motion QA: pending behind motion treatment
- OIDC evidence callback: pending behind QA

This is material progress. Task 16728 is NOT marked completed and must remain uncompleted until the OIDC callback supplies reproducible final evidence.

## Current blockers and safe parallel work

- F02/F03/F04/F05/F07/F08: authentic capture remains required.
- F06/F09: executor is actively rendering; next safe stage is real-motion QA, then focused RARA review based on the persisted runtime evidence.
- CPU/evidence/QA can continue in parallel.
- No additional GPU render was started by this repair.

## Completed in this intervention

- diagnosed missing tool-executor recipe / bridge binding / state-machine classification;
- prevented synthetic F02/F03/F04/F05/F07/F08 capture;
- upgraded F06/F09 bridge to fail closed on real-motion criteria;
- upgraded GitHub executor to deterministic motion verification;
- repaired control-plane state classification for active external recipes;
- relaunched only the affected F06/F09 route and verified material progress.

## Reassignable work

Once run 33753261598 returns a successful OIDC evidence callback, RARA can independently review F06/F09 for provenance, motion, subtitles/keyframes, SHA-256 and publication gates. F02/F03/F04/F05/F07/F08 are not reassignable to an LLM while authentic capture is absent.

## Publication and GPU safety

- No F02-F09 content was published or uploaded to a social platform.
- Any GitHub Actions artifact produced is an internal review/evidence artifact only.
- `publication_authorized=false` remains enforced.
- F10 remains HOLD.
- Shared Nebius GPU was not consumed by this F06/F09 repair.

## Next canonical step

Observe run 33753261598. Do not mark F06/F09 completed until the bridge records runtime-proven evidence. On successful evidence ingestion, release only the focused F06/F09 RARA QA path. On executor failure, diagnose the failing step and repair/re-run only that path; do not regenerate F02/F03/F04/F05/F07/F08 or reopen publication.