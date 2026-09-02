# SOCIAL OPS — CYGNUS · RARA REVIEW FAIRNESS ROOT REPAIR

UTC: 2026-09-02 22:04
Scope: F02-F09 only. No upload/publish authorization. F10 remains HOLD.

## Evidence observed
- F02: BLOCKED, MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE, lane=evidence_producer.
- F03: REVIEW_PENDING; review queue attempts=29.
- F04: REVIEW_PENDING; review queue attempts=19.
- F05: REVIEW_PENDING; review queue attempts=19 and claimed at 22:00:30Z.
- F06: BLOCKED, MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE, lane=evidence_producer.
- F07: REVIEW_PENDING; review queue attempts=4; pending since 20:15:16Z.
- F08: REVIEW_PENDING; review queue attempts=2 before intervention; pending since 19:55:15Z.
- F09: BLOCKED, MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE, lane=evidence_producer.
- Director control-plane is alive: cycle 12781 at 22:00:15Z completed with dispatched=2, no warnings, no active-state mismatches.

## Root cause
RARA review claim ordering used priority before retry/claim history:
`ORDER BY priority DESC, queue.updated_at, builder_run_id`.
Repeatedly stale/recovered high-priority reviews (notably F03/F05) kept reacquiring scarce review slots, while lower-priority F07/F08 remained pending for well over 10 minutes. Stale-claim recovery also rewrote updated_at, so queue age could not reliably provide starvation protection.

## Structural correction
Deployed migration `rara_review_claim_fairness_v4` and persisted source migration `20260902220200_rara_review_claim_fairness_v4.sql`.
New policy keeps normal priority but moves reviews with >=3 attempts behind under-attempted reviews, then orders by priority, attempts, and stable builder_run_id. This prevents a repeatedly recovered review from monopolizing RARA while preserving fail-closed review semantics.

## Validation
After deployment and an explicit auto-loop kick, F08 changed from pending/attempts=2 to CLAIMED/attempts=3 at 22:03:29Z. F03 remained pending rather than immediately reacquiring the slot. This is direct runtime evidence that the fairness ordering changed claim behavior as intended.
F07 remains pending, but it is now next in the under/reasonable-attempt cohort while two review workers are actively occupied (F05 and F08). Do not duplicate claims while those workers are active.

## Current canonical state
- F02: BLOCKED — genuine media_capture producer unavailable.
- F03: REVIEW_PENDING — pending, attempts=29; no manual duplicate claim.
- F04: REVIEW_PENDING — pending, attempts=19.
- F05: REVIEW_PENDING — actively claimed.
- F06: BLOCKED — genuine media_capture producer unavailable.
- F07: REVIEW_PENDING — pending; starvation guard now active.
- F08: REVIEW_PENDING — actively claimed after fairness repair.
- F09: BLOCKED — genuine media_capture producer unavailable.
- Uploads: 0.
- Publications: 0.
- F10: HOLD.

## Reassignable / next step
Allow current F05/F08 reviews to finish or expire normally. On the next RARA claim, fairness_v4 must prevent F03/F04/F05 retry-heavy reviews from repeatedly jumping ahead of healthier pending work. If F07 still receives no claim after a slot becomes free, treat that as a new regression and inspect worker concurrency/claim fencing, not media capability.
