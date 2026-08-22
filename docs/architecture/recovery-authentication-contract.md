# Canonical recovery authentication contract

## Root cause

Recovery previously mixed three concerns: credential storage, URI parsing, and endpoint validation. A password embedded in `SUPABASE_DB_URL` could be parsed or percent-decoded before being re-used, and the diagnostic resolver converted any failed Session Pooler probe into `auth_failed`, hiding whether the real cause was tenant, endpoint, network, or credential rejection. Re-runs could also persist diagnostics from an old workflow SHA and conflict with a newer `latest.json` commit.

## Canonical contract

1. `SUPABASE_DB_PASSWORD` is the canonical recovery credential and is treated as an opaque secret.
2. PostgreSQL receives the canonical credential only through `PGPASSWORD`; no URI reconstruction or percent-encoding is allowed on the dedicated-secret path.
3. GitHub-hosted recovery uses Supavisor Session Pooler for the ContentFlow `us-east-1` project: host `aws-0-us-east-1.pooler.supabase.com`, port `5432`, user `postgres.koqpyfvnprmirqviafzq`, database `postgres`, SSL required.
4. `SUPABASE_DB_URL` is compatibility-only. It may be used for the direct IPv6 diagnostic and as a legacy fallback only when the dedicated secret is absent.
5. Diagnostics must preserve the actual PostgreSQL failure class. `auth_failed` may be emitted only from the stderr of a real Session Pooler connection attempt.
6. A successful diagnostic requires both `pooler_ready=true` and `pooler_pg_dump_ok=true` before recovery can be treated as physically reachable.
7. Snapshot persistence must rebase its output onto the latest `main` state before writing generated evidence, preventing stale-SHA self-conflicts.
8. Recovery operations remain read-only against production; snapshot commits and artifacts contain only non-secret recovery material.

## Promotion rule

No recovery certification receipt may report PASS until the Session Pooler authenticates using the canonical dedicated secret, `pg_dump` produces non-empty output, SHA-256 evidence is generated, and the isolated restore/parity gates remain valid.
