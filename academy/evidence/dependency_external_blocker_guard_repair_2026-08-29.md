# Academy dependency guard repair — 2026-08-29

Project: `agent-academy-platform-v1`

## Finding

A live Supabase review found that two dependency reconciliation functions could still promote `blocked` tasks back to `ready` after dependencies completed, even when `blocked_reason` represented a real external prerequisite. This was independent from the previously-hardened `contentflow_sync_help_and_dependents()` trigger.

Affected functions:

- `contentflow_dependency_release_reconcile`
- `contentflow_sync_dependency_states`

This explained why the Academy web runtime tasks could reappear as `READY` even though `academy.contentflow.ai` was still not attached to the live Vercel project.

## Repair applied

Supabase migration `preserve_all_external_blockers_in_dependency_sync` upgraded the two functions so that a blocked task is only auto-released when its blocker is internal/recoverable (`NULL`/empty, `STATE_GUARD_BLOCKED_UNSPECIFIED`, or `DEPENDENCY_INCOMPLETE`). External blockers are preserved.

A second migration restored these tasks to fail-closed state:

- `academy_web_analytics_runtime_evidence_v1`
- `academy_web_accessibility_runtime_validation_v2`
- `academy_web_error_loading_runtime_validation_v2`

with blocker:

`EXTERNAL_PREREQUISITE_WEB_DOMAIN_NOT_ATTACHED_TO_VERCEL_PROJECT`

## Validation

Immediately after the repair, both reconciliation functions were executed against `agent-academy-platform-v1`.

Result:

- `DEPENDENCY_STATE_SYNC_V3_EXTERNAL_BLOCKER_SAFE`: `promoted_dispatchable = 0`
- `DEPENDENCY_RELEASE_RECONCILIATION_V2_EXTERNAL_BLOCKER_SAFE`: `released = 0`

The live Vercel project still listed only the existing Investments España / Vercel domains and did not include `academy.contentflow.ai`, so the web blocker remains valid.

## Meta

No Facebook/Instagram blocker was attributed to Work. The Academy social task remains governed by the technical Meta OAuth path and is not marked complete without a verified callback plus persisted connection evidence.
