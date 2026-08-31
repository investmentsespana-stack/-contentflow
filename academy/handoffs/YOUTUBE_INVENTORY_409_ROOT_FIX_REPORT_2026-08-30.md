# Director Report — YouTube inventory 409 root fix

Date: 2026-08-30 America/New_York
Scope: Social Ops — Cygnus / YouTube certified connection

## Incident
A fresh authenticated inventory call to `/api/youtube/demo?action=inventory` reached YouTube successfully but failed during evidence persistence with HTTP 409.

## Root cause
`public.director_external_evidence` has a unique index over:
`(project_key, task_key, evidence_type, coalesce(engine,''), coalesce(environment,''))`.

The YouTube inventory handler attempted a new INSERT whenever the previous snapshot was older than 15 minutes. Because the canonical YouTube inventory evidence row already existed, the insert violated the unique index and PostgREST returned HTTP 409.

This was an internal persistence/idempotency defect. It was NOT an OAuth failure and did NOT require reconnecting YouTube.

## Fix
Updated `src/platform/youtube-channel-inventory.mjs` so evidence persistence is idempotent:
- locate the existing canonical evidence row for the exact unique-key dimensions;
- PATCH/update that row when it exists;
- POST only when the row does not yet exist;
- use `updated_at` as freshness signal;
- preserve fail-closed channel ID verification and secret redaction.

Fix commit:
`24e42edbc449aee9cd8d816f9447aaf6541cdaa7`

## Production verification
Fresh production call after deployment:
`GET https://www.investmentsespana.space/api/youtube/demo?action=inventory`

Result:
- HTTP 200
- schema: `nexo.youtube.inventory.receipt.v1`
- status: `verified`
- evidenceId: `45`
- channelId: `UCZhxLanR9eh7u2PtMv9Bxjg`
- channelTitle: `ruben espana`
- videoCount: `0`
- playlistCount: `0`
- checkedAt: `2026-08-31T02:05:42.402Z`
- secretsExposed: `false`

## Certification impact
YouTube remains `CERTIFIED / CONNECTED_PERSISTED`.
Do NOT repeat OAuth.
The inventory persistence path is now reusable/idempotent and a stale snapshot no longer causes HTTP 409.

## Guardrails
- no OAuth repeated
- no handle changed
- no public content published
- no content deleted
- no secrets exposed
- same canonical channel only

## Reassignment
YouTube inventory incident is CLOSED. Reassign this lane to the next executable YouTube adapter/identity-verification task while preserving the no-publication gate.
