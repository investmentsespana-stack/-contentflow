# SOCIAL OPS — CYGNUS · RARA FAIRNESS V5 ROOT REPAIR

Timestamp UTC: 2026-09-02 22:56Z
Scope: F02-F09 only. No upload/publication authorization. F10 remains HOLD.

## Finding
RARA was alive, but review starvation persisted after fairness_v4. F07 remained pending since 20:15 UTC and F08 since 22:10 UTC while F03/F05, already carrying 39/23 attempts, reclaimed the two review slots at 22:50 UTC.

## Root cause
`rara_claim_review_v1()` ordered all rows with attempts >=3 first by backlog priority and only afterwards by attempt count. Consequently high-priority F03/F05 could repeatedly outrank F07/F08 despite much larger retry histories.

## Structural correction
Applied migration `rara_review_claim_fairness_v5_attempt_age_first` and persisted source as:
`supabase/migrations/20260902225400_rara_review_claim_fairness_v5_attempt_age_first.sql`

New claim ordering:
1. lowest `attempts` first;
2. oldest `available_at` first;
3. backlog priority only as a later tie-breaker;
4. stable builder_run_id tie-breaker.

Stale claims older than 3 minutes are still recovered safely before selection.

## Runtime validation
After triggering the normal control loop:
- F08 / builder_run 7274: CLAIMED at 22:55:16 UTC, attempts 3 -> 4.
- F07 / builder_run 7273: CLAIMED at 22:55:16 UTC, attempts 4 -> 5.
- F03 / builder_run 7278: returned to PENDING with 39 attempts instead of immediately monopolizing a slot.
- F04 and F05 subsequently received claims at 22:55:39 UTC under the normal RARA flow.

This demonstrates the starvation condition is removed in the observed cycle.

## Current Social Ops state
- F02: BLOCKED — MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE.
- F03: REVIEW_PENDING / pending after fairness recovery; quality 100 from producer run but no final completion inferred.
- F04: REVIEW_PENDING / claimed by RARA.
- F05: REVIEW_PENDING / claimed by RARA.
- F06: BLOCKED — MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE; review queue historical row done does not override media-capability guard.
- F07: REVIEW_PENDING / claimed by RARA after >2h starvation.
- F08: REVIEW_PENDING / claimed by RARA after >40m starvation.
- F09: BLOCKED — MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE.

## Guardrails
- No evidence fabricated.
- No `completed` inferred from review quality alone.
- No uploads or publications performed.
- F10 remains HOLD.
- GPU path remains serialized under the certified Avatar contract; no GPU work was forced in this repair.

## Reassignable work / next step
Allow current RARA claims to finish. On the next control cycle, verify F07/F08 progress/terminal state and ensure F03 cannot starve lower-attempt review work again. Media-capture-blocked F02/F06/F09 remain fail-closed until a real certified media_capture producer exists.
