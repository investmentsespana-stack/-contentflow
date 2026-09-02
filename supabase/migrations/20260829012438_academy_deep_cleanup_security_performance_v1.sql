-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

-- Low-risk performance hardening for evidence joins.
create index if not exists idx_cf_evidence_requirements_backlog_task_id on public.contentflow_evidence_requirements(backlog_task_id);
create index if not exists idx_cf_evidence_requirements_source_run_id on public.contentflow_evidence_requirements(source_run_id);
create index if not exists idx_cf_runtime_evidence_backlog_task_id on public.contentflow_runtime_evidence_ledger(backlog_task_id);
create index if not exists idx_cf_runtime_evidence_builder_run_id on public.contentflow_runtime_evidence_ledger(builder_run_id);
create index if not exists idx_cf_runtime_evidence_requirement_id on public.contentflow_runtime_evidence_ledger(requirement_id);

-- Internal control/evidence tables must not be publicly readable/writable by default.
alter table public.director_recovery_learning_memory enable row level security;
alter table public.contentflow_capability_certifications enable row level security;
alter table public.contentflow_primary_source_evidence enable row level security;
alter table public.director_project_task_scope enable row level security;
alter table public.contentflow_durable_task_stages enable row level security;

-- Restrict clearly internal Academy/planning control-plane RPCs.
revoke execute on function public.academy_configure_web_runtime_executor_v1() from anon, authenticated;
grant execute on function public.academy_configure_web_runtime_executor_v1() to service_role;
revoke execute on function public.academy_plan_execution_buffer_v1(text,integer) from anon, authenticated;
grant execute on function public.academy_plan_execution_buffer_v1(text,integer) to service_role;
revoke execute on function public.contentflow_plan_execution_buffer_internal_v1(text,integer) from anon, authenticated;
grant execute on function public.contentflow_plan_execution_buffer_internal_v1(text,integer) to service_role;
