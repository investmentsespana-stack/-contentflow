-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_enforce_learned_evidence_lane()
returns trigger
language plpgsql
set search_path to 'public'
as $function$
begin
  if new.project_key='contentflow'
     and new.epic='evidence_first'
     and new.task_key like 'evidence_%'
     and coalesce(new.description,'') like 'Produce REAL, persisted, correlated evidence%'
     and new.status <> 'completed' then
    new.execution_lane := 'evidence_producer';
  end if;
  return new;
end;
$function$;
