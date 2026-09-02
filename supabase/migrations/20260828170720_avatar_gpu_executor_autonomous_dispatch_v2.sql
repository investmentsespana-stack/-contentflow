-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

alter table public.contentflow_external_executor_registry enable row level security;
revoke all on table public.contentflow_external_executor_registry from anon, authenticated;
grant select,insert,update,delete on table public.contentflow_external_executor_registry to service_role;

select cron.unschedule(jobid) from cron.job where jobname='avatar-direct-tool-kick-1m';
select cron.schedule(
  'avatar-direct-tool-kick-1m',
  '* * * * *',
  $$select net.http_post(
      url:='https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/contentflow-direct-tool-kick-avatar',
      headers:='{"Content-Type":"application/json"}'::jsonb,
      body:='{}'::jsonb,
      timeout_milliseconds:=30000
    );$$
);

create or replace function public.contentflow_reconcile_external_executor_waits_v1(p_project_key text default 'contentflow')
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_blocked int:=0; v_released int:=0;
begin
  update public.contentflow_build_backlog b
     set status='blocked',blocked_reason='EXECUTOR_ENDPOINT_REQUIRED',next_eligible_at=null,updated_at=now()
   where b.project_key=p_project_key
     and b.execution_lane='tool_executor'
     and coalesce((b.workflow_contract->>'runtime_required')::boolean,false)=true
     and coalesce(b.workflow_contract->'execution_recipe'->>'executor_key','')<>''
     and not public.contentflow_external_executor_ready(b.project_key,b.workflow_contract->'execution_recipe'->>'executor_key')
     and b.status in ('ready','planned');
  get diagnostics v_blocked=row_count;

  update public.contentflow_build_backlog b
     set status='ready',blocked_reason=null,next_eligible_at=now(),updated_at=now()
   where b.project_key=p_project_key
     and b.execution_lane='tool_executor'
     and coalesce(b.workflow_contract->'execution_recipe'->>'executor_key','')<>''
     and public.contentflow_external_executor_ready(b.project_key,b.workflow_contract->'execution_recipe'->>'executor_key')
     and b.status='blocked' and b.blocked_reason='EXECUTOR_ENDPOINT_REQUIRED';
  get diagnostics v_released=row_count;

  perform public.contentflow_sync_tool_execution_queue(p_project_key);
  return jsonb_build_object('architecture','EXTERNAL_EXECUTOR_DURABLE_WAIT_V1','blocked_missing_executor',v_blocked,'released_executor_ready',v_released);
end;
$$;
