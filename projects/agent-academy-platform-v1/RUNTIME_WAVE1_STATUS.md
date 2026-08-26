# Agent Academy & Professional Cloud — Runtime Wave 1 Status

Project key: `agent-academy-platform-v1`
Environment executed: Supabase recovery sandbox `fbdowkcojgszqfrkgwis`
Production mutation: **NO**

## Certified architecture gate

`academy_mvp_wave1_gate_v1` — COMPLETED — quality 95 — independent review approved.

Verdicts:
- Controlled sandbox implementation: **GO**
- Customer-facing canary: **NO-GO** pending internal control-plane security remediation and full authenticated API E2E
- Commercial production: **NO-GO**

## Applied sandbox migrations

The exact executed SQL is retained in `supabase_migrations.schema_migrations` in the sandbox.

| Version | Migration | Result |
|---|---|---|
| `20260826004548` | `academy_customer_plane_sandbox_v1` | Applied |
| `20260826005554` | `academy_wave1_audit360_course_factory_v1` | Applied |
| `20260826005844` | `academy_tutor_context_runtime_v1` | Applied |

## Runtime canaries

### Customer data-plane RLS

Task: `academy_runtime_customer_plane_rls_canary_v1`
Runtime verified: **PASS / 100**

Demonstrated:
1. Tenant A can read only Tenant A.
2. Tenant B can read only Tenant B.
3. Own enrollment write succeeds.
4. Cross-tenant enrollment write is blocked by RLS.
5. Missing `auth.uid()` fails closed with zero visible customer rows.
6. `anon` direct read is denied.
7. Tenant admin sees only its tenant memberships.
8. Composite tenant foreign keys block cross-tenant entity mixing even server-side.

### Audit360 + unit economics

Task: `academy_runtime_audit360_economics_canary_v1`
Runtime verified: **PASS / 100**
Synthetic canary data only; no customer financial claims.

Audit360 result:
- AOS: `0.875`
- TFS: `0.955`
- execution completeness: `1.0`
- financial confidence: `0.925`
- decision: `GO`

Unit economics behavior:
- Before required variables: `NEEDS_EVIDENCE` with 20 missing variables.
- After explicitly verified synthetic variables: `PASS`.
- Synthetic result: cost `16.312`, revenue `100`, payment fees `3`, operating margin `0.80688`.

The values above are test fixtures, not prices or forecasts.

### Course Factory

Task: `academy_runtime_course_factory_canary_v1`
Runtime verified: **PASS / 100**

Pilot canary:
- 2 primary sources -> `needs_evidence`
- 3 sources -> `research_verified`
- sequential execution through all 10 contracts
- Judge score: `95`
- Verifier final state: `verified_certified`
- course status: `certified`
- course version status: `certified`
- persisted agent-run records: `11` (initial research attempt + full 10-agent chain)

### Tutor context

Task: `academy_runtime_tutor_context_canary_v1`
Runtime verified: **PASS / 100**

Implementation uses `SECURITY INVOKER` plus customer-plane RLS; it does not bypass RLS and does not read the six internal RLS-disabled control-plane tables.

Canary user A:
- active certified course resolved
- module and lesson resolved
- progress `in_progress`
- max context chars: `900`
- actual context chars: `881`
- approximate tokens: `221`
- content truncation: `true`
- trace event persisted

Canary user B with no enrollment returned a safe empty context.

## Learning API

Supabase Edge Function: `academy-learning-api`
Sandbox version: `1`
Status: `ACTIVE`
JWT verification: **enabled**

Implemented routes:
- `GET /courses`
- `GET /enrollments`
- `GET /certifications`
- `GET /tutor-context`
- `POST /enroll`
- `POST|PUT /progress`
- `POST /assessment-submit`

Unauthenticated smoke test: **PASS** — HTTP `401 UNAUTHORIZED_NO_AUTH_HEADER`.

Authenticated HTTP E2E: **PENDING**. No runtime verification claim is made until a real sandbox Auth session can be used safely.

## Control-plane security blocker

Production/internal RLS changes were deliberately **not** applied.

Live evidence shows the original six internal tables are not one uniform case:
- `contentflow_workflow_e2e_state`: no direct anon/authenticated grants; currently service/postgres only.
- `contentflow_capability_certifications` and `contentflow_durable_task_stages`: broad direct grants but service-role-only SECURITY DEFINER callers.
- `director_project_task_scope`: live caller `avatar_product_progress_v1()` is SECURITY DEFINER and service-role-only; a previous recommendation to replace the table was too aggressive.
- `director_recovery_learning_memory`: the 2-argument `director_recovery_learning_decision(text,text)` is SECURITY INVOKER and executable by anon/authenticated; direct grant revocation would break that interface unless it is migrated or retired first.
- `contentflow_primary_source_evidence`: primary-source helper functions are already SECURITY DEFINER, but execute ACL and direct-table access must be redesigned together.

Therefore there is no blind production RLS migration. Each table requires caller-aware remediation and sandbox validation first.

## Next runtime gate

1. Create caller-aware internal-table security remediation v2 and test it in a synchronized environment before production changes.
2. Complete authenticated HTTP E2E for `academy-learning-api` using a legitimate sandbox Auth session.
3. Connect the Course Factory runtime to real ContentFlow agent tasks and primary-source evidence, replacing synthetic canary evidence.
4. Only after those pass, re-evaluate customer-facing canary GO/NO-GO.
