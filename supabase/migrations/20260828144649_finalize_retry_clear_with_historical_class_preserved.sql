-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

CREATE OR REPLACE FUNCTION public.contentflow_clear_retry_after_repair(p_task_key text, p_project_key text DEFAULT 'contentflow'::text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare
  v_last_run_id bigint;
begin
  select max(id) into v_last_run_id
  from public.contentflow_builder_runs
  where project_key=p_project_key and task_key=p_task_key and finished_at is not null;

  update public.contentflow_retry_state
     set attempt_count=0,
         last_run_id=coalesce(v_last_run_id,last_run_id),
         last_error=null,
         next_retry_at=null,
         circuit_state='closed',
         circuit_open_until=null,
         updated_at=now()
   where project_key=p_project_key and task_key=p_task_key;

  update public.contentflow_build_backlog
     set next_eligible_at=now(),
         blocked_reason=null,
         updated_at=now()
   where project_key=p_project_key and task_key=p_task_key
     and status in ('ready','blocked','planned');
  return found;
end
$function$;

CREATE OR REPLACE FUNCTION public.contentflow_clear_retry_after_repair(p_task_key text)
RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
begin
  return public.contentflow_clear_retry_after_repair(p_task_key,'contentflow');
end
$function$;
