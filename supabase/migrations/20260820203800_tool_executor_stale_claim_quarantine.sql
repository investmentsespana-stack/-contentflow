-- TOOL_EXECUTOR_STALE_CLAIM_QUARANTINE_V1
create or replace function public.contentflow_sync_tool_execution_queue(p_project_key text default 'contentflow')
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare n int:=0; reactivated int:=0; quarantined int:=0;
begin
  insert into public.contentflow_tool_execution_queue(project_key,backlog_task_id,task_key,state,updated_at)
  select b.project_key,b.id,b.task_key,'pending',now()
  from public.contentflow_build_backlog b
  where b.project_key=p_project_key and b.execution_lane='tool_executor' and b.status in ('blocked','ready')
    and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.value and x.status='completed'))
  on conflict(project_key,backlog_task_id) do nothing;
  get diagnostics n=row_count;

  update public.contentflow_tool_execution_queue q set state='pending',updated_at=now()
  where q.project_key=p_project_key and q.state='blocked'
    and exists(select 1 from public.contentflow_build_backlog b where b.id=q.backlog_task_id and b.execution_lane='tool_executor' and b.status in ('blocked','ready') and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.value and x.status='completed')));
  get diagnostics reactivated=row_count;

  -- Revoke stale claims that no longer belong to the tool lane. Never touch a running backlog item.
  update public.contentflow_tool_execution_queue q
     set state='blocked',claim_token=null,claimed_at=null,updated_at=now(),last_error=coalesce(q.last_error,'')||case when coalesce(q.last_error,'')='' then '' else ' | ' end||'QUARANTINED_OFF_LANE_STALE_CLAIM'
   where q.project_key=p_project_key and q.state='claimed'
     and exists(select 1 from public.contentflow_build_backlog b where b.id=q.backlog_task_id and b.execution_lane<>'tool_executor' and b.status<>'running');
  get diagnostics quarantined=row_count;

  update public.contentflow_tool_execution_queue q set state='blocked',updated_at=now()
  where q.project_key=p_project_key and q.state='pending'
    and exists(select 1 from public.contentflow_build_backlog b where b.id=q.backlog_task_id and (b.execution_lane<>'tool_executor' or b.status not in ('blocked','ready')));

  return jsonb_build_object('synced',n,'reactivated',reactivated,'quarantined_claims',quarantined,'pending',(select count(*) from public.contentflow_tool_execution_queue where project_key=p_project_key and state='pending'),'failed_held',(select count(*) from public.contentflow_tool_execution_queue where project_key=p_project_key and state='failed'));
end;
$$;
