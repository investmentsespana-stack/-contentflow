-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.academy_plan_execution_buffer_v1(p_project_key text default 'agent-academy-platform-v1', p_target integer default 10)
returns jsonb
language plpgsql
security definer
set search_path='public'
as $function$
declare
  v_dispatchable int:=0;
  v_waiting int:=0;
  v_external_blockers int:=0;
  v_internal_blockers int:=0;
  v_tool_pending int:=0;
  v_review_pending int:=0;
  v_summary jsonb:='{}'::jsonb;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;
  if p_project_key<>'agent-academy-platform-v1' then return jsonb_build_object('ok',false,'reason','academy_scope_only'); end if;

  select public.contentflow_dispatchable_count(p_project_key) into v_dispatchable;

  select count(*) into v_waiting
  from public.contentflow_build_backlog b
  where b.project_key=p_project_key and b.status in ('planned','ready','verification_required');

  select count(distinct d.id) into v_external_blockers
  from public.contentflow_build_backlog b
  cross join lateral jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
  join public.contentflow_build_backlog d on d.project_key=b.project_key and d.task_key=dep.value
  where b.project_key=p_project_key and b.status in ('planned','ready')
    and d.status='blocked'
    and coalesce(d.blocked_reason,'') like 'EXTERNAL_%';

  select count(distinct d.id) into v_internal_blockers
  from public.contentflow_build_backlog b
  cross join lateral jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
  join public.contentflow_build_backlog d on d.project_key=b.project_key and d.task_key=dep.value
  where b.project_key=p_project_key and b.status in ('planned','ready')
    and d.status not in ('completed','blocked');

  select count(*) into v_tool_pending from public.contentflow_tool_execution_queue q
  join public.contentflow_build_backlog b on b.id=q.backlog_task_id
  where q.project_key=p_project_key and q.state='pending' and b.status in ('blocked','ready');

  select count(*) into v_review_pending from public.contentflow_review_work_queue q
  join public.contentflow_builder_runs r on r.id=q.builder_run_id
  where r.project_key=p_project_key and q.state='pending' and q.available_at<=now();

  v_summary:=jsonb_build_object(
    'architecture','ACADEMY_IDLE_DEPENDENCY_AWARE_PLANNER_V1',
    'target',greatest(1,least(coalesce(p_target,10),20)),
    'dispatchable_llm',v_dispatchable,
    'waiting_tasks',v_waiting,
    'external_blocking_dependencies',v_external_blockers,
    'internal_blocking_dependencies',v_internal_blockers,
    'tool_pending',v_tool_pending,
    'review_pending',v_review_pending,
    'classification',case when v_dispatchable>0 then 'executable_work_available' when v_external_blockers>0 then 'dependency_blocked_not_idle' when v_waiting>0 then 'internal_dependency_wait' else 'true_idle' end
  );

  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
  values(p_project_key,'academy_idle_plan','academy_dependency_aware_planner_v1','dependency_aware_support',
    case when v_dispatchable>0 then 'work_available' when v_external_blockers>0 then 'external_dependency_wait_preserve_parallel_support' when v_waiting>0 then 'internal_dependency_wait' else 'true_idle' end,
    false,v_summary::text,now());

  return v_summary;
end
$function$;

create or replace function public.contentflow_plan_execution_buffer(p_project_key text default 'contentflow', p_target integer default 10)
returns jsonb
language plpgsql
security definer
set search_path='public'
as $function$
begin
  if p_project_key='agent-academy-platform-v1' then
    return public.academy_plan_execution_buffer_v1(p_project_key,p_target);
  end if;
  if p_project_key<>'contentflow' then
    return jsonb_build_object('ok',true,'architecture','INFRASTRUCTURE_PLANNER_SCOPE_GUARD_V2','scope','unsupported_project','project_key',p_project_key,'skipped',true);
  end if;
  return public.contentflow_plan_execution_buffer_internal_v1(p_project_key,p_target);
end
$function$;
