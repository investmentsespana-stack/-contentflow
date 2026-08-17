# ContentFlow Secret Source Map

## Scope

This document is the auditable mapping for secret/configuration access in the canonical ContentFlow runtime. It was produced from the active Supabase Edge Function deployments and the repository runtime paths. Secret values are intentionally never recorded here.

## Approved source patterns

ContentFlow permits only these source channels:

1. `supabase_edge_secret` — server-side secret injected into a Supabase Edge Function and read with `Deno.env.get(...)`. Secret values must never be committed to GitHub or emitted to logs/results.
2. `service_role_rls_table` — server-only internal secret stored in a dedicated RLS-enabled table whose ACL is restricted to `postgres` and `service_role`, fetched only by a service-role Edge Function and used only for internal authenticated calls.
3. `public_config` — non-secret platform configuration such as `SUPABASE_URL` or the publishable/anon key. These values are not treated as privileged credentials and must not authorize privileged actions.

Direct secret literals in source, client-exposed service-role credentials, unprotected database secret storage, and arbitrary direct Vault/Secrets Manager calls are not approved.

## Mapping

| Reference | Classification | Source channel | Canonical consumers | Purpose | Validation |
|---|---|---|---|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | secret | `supabase_edge_secret` | `contentflow-auto-loop` v27, `contentflow-rara` v9, `contentflow-builder-agent-runner-v2` v5, `contentflow-dispatch-executor-v2` v1 | server-to-server Supabase access and authenticated internal function calls | Read only with `Deno.env.get`; not embedded in response payloads; never used by browser code |
| `NEXOROUTER_API_KEY` | secret | `supabase_edge_secret` | `contentflow-rara` v9, `contentflow-builder-agent-runner-v2` v5 | authenticated NexoRouter inference/QA requests | Read only with `Deno.env.get`; sent only in outbound `Authorization: Bearer` header to NexoRouter |
| `runner_secret` | secret | `service_role_rls_table` | `contentflow-builder-agent-runner-v2` v5, `contentflow-dispatch-executor-v2` v1 | fenced internal executor/runner authentication | Stored in `public.contentflow_internal_runner_config`; RLS enabled; table ACL restricted to `postgres` and `service_role`; compared server-side and passed only as `X-ContentFlow-Internal` between canonical internal functions |
| `SUPABASE_URL` | public config | `public_config` | canonical Edge Functions and `contentflow-app` | project API endpoint | Read with `Deno.env.get`; contains no privileged credential |
| `SUPABASE_ANON_KEY` | public/publishable config | `public_config` | `contentflow-app` | authenticated browser client using RLS | Browser-visible by design; must never be substituted with service role |

## Runtime-path findings

- `contentflow-auto-loop` v27 uses `SUPABASE_URL` and `SUPABASE_SERVICE_ROLE_KEY` from the Edge Function environment. It forwards the service-role credential only on internal server-to-server calls.
- `contentflow-rara` v9 uses `SUPABASE_SERVICE_ROLE_KEY` and `NEXOROUTER_API_KEY` from the Edge Function environment. The Nexo key is used only for the NexoRouter authorization header.
- `contentflow-builder-agent-runner-v2` v5 uses `SUPABASE_SERVICE_ROLE_KEY` and `NEXOROUTER_API_KEY` from the Edge Function environment. Its additional internal `runner_secret` is fetched from the restricted RLS table and compared server-side.
- `contentflow-dispatch-executor-v2` v1 uses `SUPABASE_SERVICE_ROLE_KEY` from the Edge Function environment and fetches `runner_secret` from the restricted RLS table before calling the runner.
- `contentflow-app` uses only `SUPABASE_URL` and `SUPABASE_ANON_KEY`; no privileged secret is sent to the browser.

## Security invariants

- No service-role or NexoRouter secret may be committed to the repository.
- No privileged secret may be rendered into HTML, JSON responses, logs, metrics, or task artifacts.
- `runner_secret` must remain behind RLS and a service-role-only ACL; moving it to a generally readable table is prohibited.
- Browser code may use only public/publishable configuration.
- New secret references must be added to this map and must use one of the approved channels above before deployment.
- Any secret source outside this map fails the deployment/security gate until reviewed.

## Evidence baseline

The mapping was checked against the active canonical runtime versions listed above and against the current database protection for `contentflow_internal_runner_config` (RLS enabled; ACL limited to `postgres` and `service_role`). No secret values were copied during the audit.
