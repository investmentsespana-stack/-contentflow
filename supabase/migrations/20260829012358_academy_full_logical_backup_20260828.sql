-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create schema if not exists backup_academy_20260828;

create table if not exists backup_academy_20260828.manifest(
  id bigint generated always as identity primary key,
  snapshot_at timestamptz not null default now(),
  project_key text not null,
  source_project_id text not null,
  note text not null
);

create table if not exists backup_academy_20260828.project_rows(
  table_name text not null,
  row_data jsonb not null
);

create table if not exists backup_academy_20260828.related_rows(
  table_name text not null,
  row_data jsonb not null
);

create table if not exists backup_academy_20260828.function_defs(
  function_identity text primary key,
  definition text not null
);

truncate backup_academy_20260828.project_rows;
truncate backup_academy_20260828.related_rows;
truncate backup_academy_20260828.function_defs;

insert into backup_academy_20260828.manifest(project_key,source_project_id,note)
values ('agent-academy-platform-v1','koqpyfvnprmirqviafzq','Pre-cleanup logical snapshot of Academy project state, related runtime/evidence records, and orchestration function definitions. Secrets/config tables without project_key intentionally excluded.');

do $$
declare r record;
begin
  for r in
    select table_name
    from information_schema.columns
    where table_schema='public' and column_name='project_key'
    group by table_name
  loop
    execute format(
      'insert into backup_academy_20260828.project_rows(table_name,row_data) select %L,to_jsonb(t) from public.%I t where project_key=%L',
      r.table_name,r.table_name,'agent-academy-platform-v1'
    );
  end loop;
end $$;

-- Related rows in key tables that may not carry project_key directly.
do $$
begin
  if to_regclass('public.contentflow_runtime_event_ledger') is not null then
    insert into backup_academy_20260828.related_rows(table_name,row_data)
    select 'contentflow_runtime_event_ledger',to_jsonb(e)
    from public.contentflow_runtime_event_ledger e
    where exists (select 1 from public.contentflow_builder_runs r where r.id=e.builder_run_id and r.project_key='agent-academy-platform-v1');
  end if;
  if to_regclass('public.contentflow_builder_dispatches') is not null then
    insert into backup_academy_20260828.related_rows(table_name,row_data)
    select 'contentflow_builder_dispatches',to_jsonb(d)
    from public.contentflow_builder_dispatches d
    where exists (select 1 from public.contentflow_build_backlog b where b.id=d.backlog_task_id and b.project_key='agent-academy-platform-v1');
  end if;
  if to_regclass('public.contentflow_retry_state') is not null then
    insert into backup_academy_20260828.related_rows(table_name,row_data)
    select 'contentflow_retry_state',to_jsonb(s)
    from public.contentflow_retry_state s
    where exists (select 1 from public.contentflow_build_backlog b where b.id=s.backlog_task_id and b.project_key='agent-academy-platform-v1');
  end if;
  if to_regclass('public.contentflow_evidence_requirements') is not null then
    insert into backup_academy_20260828.related_rows(table_name,row_data)
    select 'contentflow_evidence_requirements',to_jsonb(e)
    from public.contentflow_evidence_requirements e
    where exists (select 1 from public.contentflow_build_backlog b where b.id=e.backlog_task_id and b.project_key='agent-academy-platform-v1');
  end if;
  if to_regclass('public.contentflow_runtime_evidence_ledger') is not null then
    insert into backup_academy_20260828.related_rows(table_name,row_data)
    select 'contentflow_runtime_evidence_ledger',to_jsonb(e)
    from public.contentflow_runtime_evidence_ledger e
    where exists (select 1 from public.contentflow_build_backlog b where b.id=e.backlog_task_id and b.project_key='agent-academy-platform-v1');
  end if;
end $$;

insert into backup_academy_20260828.function_defs(function_identity,definition)
select n.nspname||'.'||p.proname||'('||pg_get_function_identity_arguments(p.oid)||')',pg_get_functiondef(p.oid)
from pg_proc p
join pg_namespace n on n.oid=p.pronamespace
where n.nspname='public'
  and (p.proname like 'academy_%' or p.proname like 'contentflow_%' or p.proname like 'director_%' or p.proname like 'rara_%')
on conflict(function_identity) do update set definition=excluded.definition;
