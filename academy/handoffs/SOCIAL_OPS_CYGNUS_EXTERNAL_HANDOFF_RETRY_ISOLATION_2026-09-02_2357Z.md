# SOCIAL OPS — CYGNUS · CANONICAL DIRECTOR REPORT

Timestamp UTC: 2026-09-02 23:57Z
Scope: Social Ops / Cygnus, F02-F09 and newly ingested external handoffs.
Publication guard: CLOSED. No upload/publication authorized. F10 remains HOLD.

## Trigger for ChatGPT-level intervention

The Director had remained in `support_only` for more than 10 minutes even though independent LLM work remained dispatchable. Root telemetry showed `retry_budget_unhealthy` caused by three recent OPEN retry circuits. Inspection proved those circuits belonged to `external_handoff` tasks whose failures were authentic external-evidence / Meta / media-capture blockers, not systemic runtime failures.

## Root cause 1 — global retry health polluted by external handoff circuits

`contentflow-auto-loop` v65 counted every retry circuit correlated with a recent builder run. External handoffs that correctly failed closed on unavailable authentic evidence therefore increased the global retry-open ratio and stopped the Director globally.

### Structural correction

Deployed `contentflow-auto-loop` v66:

`DURABLE_EXECUTION_CONTROL_LOOP_V12_EXTERNAL_HANDOFF_RETRY_ISOLATION`

Global retry-health admission now evaluates only non-`external_handoff` runs. Open circuits belonging to external handoffs remain locally blocking and are reported as `isolated_external_handoff_open_circuits`, but cannot stop independent work.

Source persisted in GitHub commit:

`25aafb369f31734c72e7d971925360e9f13e1e39`

### Runtime validation

Manual validation request 25304 returned HTTP 200 and `admitted=true`, `mode=productive`, `openCircuits=0`, `retryStates=1`, while separately reporting `isolated_external_handoff_open_circuits=3`.

Director cycle 12838 completed with 2 dispatched workers, 2 running, capacity respected, and 0 active-state mismatches.

The next scheduled control cycle at 23:55 UTC remained productive and cycle 12840 dispatched 2 workers with 0 active-state mismatches.

## Root cause 2 — new Social Ops media handoff regressed to `llm_artifact`

New handoff family `handoff_beadbe9291de_01..06` includes authentic screen capture, F02/F03 rendering on Nebius, MP4 variants, audiovisual QA receipts, keyframes, subtitles, SHA-256 provenance and additional F06/F09 captures.

The generic `contentflow_ingest_handoff_v1` hard-coded every external handoff as `execution_lane='llm_artifact'`. As a result, tasks `_02` and `_03` were incorrectly claimed by LLM workers as runs 7311 and 7310 despite requiring real media/tool execution.

### Structural correction

Applied migration `handoff_media_capture_lane_classifier_v2` and persisted:

`supabase/migrations/20260902235600_handoff_media_capture_lane_classifier_v2.sql`

GitHub commit:

`7810d9faac96096b9c924d13a9d8ceb36f9441ed`

`contentflow_ingest_handoff_v1` now classifies media-bearing handoff actions through the canonical `contentflow_evidence_prerequisite_class` plus explicit media terms. Media tasks enter `evidence_producer / evidence_pending` and fail closed with `MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE` instead of being offered to LLM workers.

Incorrect active LLM claims in the new handoff were deferred and worker slots released. Existing retry circuits for those media tasks were closed so they cannot poison global health.

## F02-F09 current state

- F02: blocked by `MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE`; no new fabricated completion accepted.
- F03: `REVIEW_PENDING`; RARA queue pending, 39 attempts. Not duplicated while lower-attempt reviews are actively claimed.
- F04: RARA CLAIMED at 23:55:29 UTC, attempt 25.
- F05: RARA CLAIMED at 23:55:29 UTC, attempt 25.
- F06: blocked by `MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE`.
- F07: RARA CLAIMED at 23:54:14 UTC, attempt 15.
- F08: RARA CLAIMED at 23:54:14 UTC, attempt 15.
- F09: blocked by `MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE`; prior missing subtitles/keyframes/SHA-256 evidence remains unresolved and no evidence is invented.

RARA is therefore actively consuming F04/F05/F07/F08 now. F03 remains queued under the attempt-age fairness policy and should not steal slots from less-retried reviews.

## Newly assigned work

The `beadbe9291de` handoff introduced six tasks covering F02/F03 authentic capture, Nebius render, audiovisual QA, Director review pack, and follow-on F06/F09 capture work. All media-dependent entries are now routed fail-closed to `evidence_producer` rather than generic LLM workers.

## Residual warning

`contentflow_normalize_dispatchability` is intermittently returning `canceling statement due to statement timeout`. This currently does not stop admission or Director dispatch after v66, but it remains a control-plane performance warning to profile separately. No unsafe bypass was applied.

Some media tasks show stale textual `blocked_reason='RETRY_CIRCUIT_OPEN'` even where the retry circuit is actually closed; execution lane and circuit state are authoritative, and the tasks remain fail-closed because media-capture capability is unavailable. This label inconsistency is non-executable and does not reopen LLM dispatch.

## Completed in this intervention

1. Isolated external-handoff retry circuits from global retry-health admission.
2. Restored productive Director dispatch and validated two successive cycles.
3. Detected the new Social Ops handoff.
4. Prevented real-media tasks from being executed by generic LLM workers.
5. Persisted runtime and source changes in GitHub.
6. Preserved all publication/upload guardrails.

## Reassignable / next safe work

CPU/evidence metadata, scripts, caption text, provenance planning and non-media QA may continue in parallel where they do not claim authentic media completion. Real screen capture, Nebius render, MP4/subtitle/keyframe/SHA-256 creation remain blocked until a certified `media_capture` producer is available. Shared GPU usage must remain serialized under Avatar's certified contract.

No upload or publication is authorized. F10 remains HOLD.
