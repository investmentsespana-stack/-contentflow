# ContentFlow Supabase -> GitHub/Codex Runtime Migration

Verified production project: `koqpyfvnprmirqviafzq` (ContentFlow AI).

## Baseline
- Production Edge Functions discovered: 37
- GitHub Edge Functions before correction: 1 (`contentflow-app`)
- Database objects observed in public schema: 52 tables, 10 views, 66 functions, 24 triggers
- `supabase/migrations/` was not present at baseline.

## Runtime source now versioned from production
- `contentflow-app` (existing)
- `contentflow-auto-loop` v26
- `contentflow-rara` v4
- `contentflow-director-control` v3

## Backup automation
`.github/workflows/daily-recovery-snapshot.yml` now defines a daily UTC recovery snapshot. It captures:
1. schema-only SQL for reproducibility;
2. non-secret Director/runtime-control data;
3. a restore manifest;
4. an automatic Git commit under `backups/YYYY-MM-DD/`.

The workflow intentionally does **not** commit arbitrary application/user data or secrets.

### Required repository secret
`SUPABASE_DB_URL` must be configured in GitHub Actions secrets before the scheduled backup can execute successfully. This secret must use a database connection with sufficient read privileges for `pg_dump` and must never be committed to the repository.

## Remaining migration work
- Version remaining production Edge Functions.
- Generate canonical `supabase/migrations/` from the live database rather than hand-writing DDL.
- Version cron configuration and security policies.
- Add restore verification in an isolated environment.
- Resolve Supabase security-advisor findings before declaring Codex/GitHub the complete source of truth.

## Completion rule
Migration is complete only when a clean environment can be reconstructed from GitHub plus external secrets and passes the Director runtime/QA checks without depending on undeclared objects that exist only in production Supabase.
