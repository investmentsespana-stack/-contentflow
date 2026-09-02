-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create table if not exists public.contentflow_external_executor_registry (
  project_key text not null,
  executor_key text not null,
  endpoint text,
  status text not null default 'unconfigured',
  capabilities jsonb not null default '{}'::jsonb,
  verified_at timestamptz,
  last_health jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key(project_key,executor_key),
  constraint contentflow_external_executor_registry_status_chk check(status in ('unconfigured','configured','healthy','degraded','offline'))
);

create or replace function public.contentflow_external_executor_ready(p_project_key text,p_executor_key text)
returns boolean language sql stable security definer set search_path=public as $$
select exists(
  select 1 from public.contentflow_external_executor_registry
  where project_key=p_project_key and executor_key=p_executor_key
    and status in ('configured','healthy')
    and nullif(endpoint,'') is not null
);
$$;

create or replace function public.contentflow_external_executor_autorelease_v1()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.status in ('configured','healthy') and nullif(new.endpoint,'') is not null then
    update public.contentflow_build_backlog b
       set status='ready',blocked_reason=null,next_eligible_at=now(),updated_at=now()
     where b.project_key=new.project_key
       and b.execution_lane='tool_executor'
       and coalesce(b.workflow_contract->'execution_recipe'->>'executor_key','')=new.executor_key
       and b.status='blocked'
       and coalesce(b.blocked_reason,'')='EXECUTOR_ENDPOINT_REQUIRED';

    update public.contentflow_tool_execution_queue q
       set state='pending',last_error=null,claim_token=null,claimed_at=null,updated_at=now()
     where q.project_key=new.project_key
       and q.state in ('failed','blocked')
       and exists(
         select 1 from public.contentflow_build_backlog b
         where b.id=q.backlog_task_id
           and b.execution_lane='tool_executor'
           and coalesce(b.workflow_contract->'execution_recipe'->>'executor_key','')=new.executor_key
       );
  end if;
  return new;
end;
$$;

drop trigger if exists trg_contentflow_external_executor_autorelease_v1 on public.contentflow_external_executor_registry;
create trigger trg_contentflow_external_executor_autorelease_v1
after insert or update on public.contentflow_external_executor_registry
for each row execute function public.contentflow_external_executor_autorelease_v1();

insert into public.contentflow_external_executor_registry(project_key,executor_key,status,capabilities,updated_at)
values('avatar-platform-v1','avatar_gpu_benchmark','unconfigured',jsonb_build_object('metrics',jsonb_build_array('latency','fps','vram','stability','lipsync_timing')) ,now())
on conflict(project_key,executor_key) do update set capabilities=excluded.capabilities,updated_at=now();

update public.contentflow_build_backlog
set status='blocked',
    blocked_reason='EXECUTOR_ENDPOINT_REQUIRED',
    next_eligible_at=null,
    workflow_contract=coalesce(workflow_contract,'{}'::jsonb) || jsonb_build_object(
      'execution_recipe',jsonb_build_object(
        'handler','edge_function',
        'function','avatar-gpu-benchmark-dispatch',
        'executor_key','avatar_gpu_benchmark',
        'deterministic',true
      ),
      'external_executor_contract_version','1'
    ),
    updated_at=now()
where project_key='avatar-platform-v1' and task_key='avatar_phase2_latency_validation_v1';

update public.contentflow_tool_execution_queue
set state='blocked',last_error='EXECUTOR_ENDPOINT_REQUIRED',claim_token=null,claimed_at=null,updated_at=now()
where project_key='avatar-platform-v1' and task_key='avatar_phase2_latency_validation_v1' and state<>'completed';
