-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_dependency_release_reconcile(p_project_key text default 'contentflow'::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare released int:=0; held_deps int:=0; held_circuit int:=0; held_capability int:=0;
begin
  update public.contentflow_build_backlog b
     set status='ready',updated_at=now(),selected_model=null,blocked_reason=null,next_eligible_at=now()
   where b.project_key=p_project_key
     and b.status='blocked'
     and coalesce(b.blocked_reason,'') in ('','STATE_GUARD_BLOCKED_UNSPECIFIED','DEPENDENCY_INCOMPLETE')
     and (b.next_eligible_at is null or b.next_eligible_at<=now())
     and not exists(select 1 from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open')
     and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value) where not exists(select 1 from public.contentflow_build_backlog d where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'))
     and (coalesce(b.execution_lane,'llm_artifact') not in ('tool_executor','evidence_producer') or public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key));
  get diagnostics released=row_count;
  select count(*) into held_deps from public.contentflow_build_backlog b where b.project_key=p_project_key and b.status='blocked' and exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value) where not exists(select 1 from public.contentflow_build_backlog d where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'));
  select count(*) into held_circuit from public.contentflow_build_backlog b where b.project_key=p_project_key and b.status='blocked' and exists(select 1 from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open');
  select count(*) into held_capability from public.contentflow_build_backlog b where b.project_key=p_project_key and b.status='blocked' and coalesce(b.execution_lane,'llm_artifact') in ('tool_executor','evidence_producer') and not public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key);
  perform public.contentflow_sync_tool_execution_queue(p_project_key);
  return jsonb_build_object('architecture','DEPENDENCY_RELEASE_RECONCILIATION_V2_EXTERNAL_BLOCKER_SAFE','released',released,'held_by_dependencies',held_deps,'held_by_circuit',held_circuit,'held_by_capability',held_capability);
end
$function$;

create or replace function public.contentflow_sync_dependency_states(p_project_key text default 'contentflow'::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare demoted int:=0; promoted int:=0;
begin
  update public.contentflow_build_backlog b
     set status='planned',selected_model=null,blocked_reason='DEPENDENCY_INCOMPLETE',next_eligible_at=null,updated_at=now()
   where b.project_key=p_project_key
     and b.status='ready'
     and exists(
       select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
       where not exists(
         select 1 from public.contentflow_build_backlog d
         where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'
       )
     );
  get diagnostics demoted=row_count;

  update public.contentflow_build_backlog b
     set status='ready',selected_model=null,blocked_reason=null,next_eligible_at=now(),updated_at=now()
   where b.project_key=p_project_key
     and b.status in ('planned','blocked')
     and b.task_key not like 'gap_gap_%'
     and (b.status='planned' or coalesce(b.blocked_reason,'') in ('','STATE_GUARD_BLOCKED_UNSPECIFIED','DEPENDENCY_INCOMPLETE'))
     and not exists(
       select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
       where not exists(
         select 1 from public.contentflow_build_backlog d
         where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'
       )
     )
     and not exists(
       select 1 from public.contentflow_retry_state rs
       where rs.backlog_task_id=b.id and rs.circuit_state='open'
     );
  get diagnostics promoted=row_count;

  return jsonb_build_object('architecture','DEPENDENCY_STATE_SYNC_V3_EXTERNAL_BLOCKER_SAFE','demoted_waiting',demoted,'promoted_dispatchable',promoted);
end
$function$;
