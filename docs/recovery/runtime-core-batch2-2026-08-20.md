# Runtime recoverability batch 2 — 2026-08-20

Source project: Supabase `ContentFlow AI` (`koqpyfvnprmirqviafzq`).

This batch versions currently deployed production source into GitHub without deploying or mutating Supabase production.

## Exported in this batch

- `contentflow-submit` — live version 14 — Supabase SHA-256 `7a4805cc11523934d8c1d804c3c99bcee5abfcfb6ef97c6c9ba6cc6ab97fa42e`.
- `contentflow-status` — live version 10 — Supabase SHA-256 `f3e4054eab3bb2c8b3acc1691edf1a8936ab484c1bd0a30e60eaed63374be471`.
- `contentflow-evidence-tool-runner` — live version 1 — Supabase SHA-256 `49aff4d93de74a37e18c860faa9bbe51ee22729d5491e717b7e4b327985576de`.

## Already versioned in batch 1

- `contentflow-throughput-recovery` — live version 9.
- `contentflow-adaptive-dispatcher` — live version 8.

## Still required for clean runtime rebuild

Priority order:
1. `contentflow-director` — live version 16.
2. `contentflow-orchestrator` — live version 13.
3. `contentflow-agent-team` — live version 15.
4. `contentflow-builder-agent-runner-v2` — live version 10.
5. `contentflow-dispatch-executor-v2` — live version 6.
6. `contentflow-capacity-planner` — live version 7.

After these Edge Functions are versioned, recoverability still requires canonical database migrations/policies/cron definitions and an isolated restore verification.

No secret values are included in this inventory.