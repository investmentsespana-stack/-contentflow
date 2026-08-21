-- TOOL_EXECUTOR_LANE_CONTRACT_V2
-- The current tool executor is a deterministic evidence verifier, not a generic code builder.

create or replace function public.contentflow_classify_execution_lane_fields(
  p_task_type text,
  p_description text,
  p_acceptance text
) returns text
language sql immutable
set search_path to 'public','pg_temp'
as $$
  select case
    when (
      coalesce(p_description,'') ~* '(produce REAL, persisted, correlated evidence|evidence harness:)'
      or coalesce(p_acceptance,'') ~* '(correlated to source task|do not fabricate evidence|generic LLM prose.*do not satisfy|deterministic platform evidence)'
    ) then 'tool_executor'
    else 'llm_artifact'
  end;
$$;

-- Reclassify non-running work using the corrected contract. Never move active work.
update public.contentflow_build_backlog b
set execution_lane=public.contentflow_classify_execution_lane_fields(b.task_type,b.description,b.acceptance_criteria),
    updated_at=now()
where b.project_key='contentflow'
  and b.status in ('planned','ready','blocked','verification_required')
  and b.execution_lane is distinct from public.contentflow_classify_execution_lane_fields(b.task_type,b.description,b.acceptance_criteria);

create or replace function public.contentflow_sync_tool_execution_queue(p_project_key text default 'contentflow')
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare n int:=0; reactivated int:=0;
begin
  insert into public.contentflow_tool_execution_queue(project_key,backlog_task_id,task_key,state,updated_at)
  select b.project_key,b.id,b.task_key,'pending',now()
  from public.contentflow_build_backlog b
  where b.project_key=p_project_key
    and b.execution_lane='tool_executor'
    and b.status in ('blocked','ready')
    and not exists(
      select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value)
      where not exists(
        select 1 from public.contentflow_build_backlog x
        where x.project_key=b.project_key and x.task_key=d.value and x.status='completed'
      )
    )
  on conflict(project_key,backlog_task_id) do nothing;
  get diagnostics n=row_count;

  -- Repair the old deadlock: queue=blocked while backlog is executable.
  update public.contentflow_tool_execution_queue q
     set state='pending',updated_at=now()
   where q.project_key=p_project_key and q.state='blocked'
     and exists(
       select 1 from public.contentflow_build_backlog b
       where b.id=q.backlog_task_id
         and b.execution_lane='tool_executor'
         and b.status in ('blocked','ready')
         and not exists(
           select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value)
           where not exists(
             select 1 from public.contentflow_build_backlog x
             where x.project_key=b.project_key and x.task_key=d.value and x.status='completed'
           )
         )
     );
  get diagnostics reactivated=row_count;

  -- A queued tool task that is no longer in the tool lane must not execute.
  update public.contentflow_tool_execution_queue q
     set state='blocked',updated_at=now()
   where q.project_key=p_project_key and q.state='pending'
     and exists(
       select 1 from public.contentflow_build_backlog b
       where b.id=q.backlog_task_id
         and (b.execution_lane<>'tool_executor' or b.status not in ('blocked','ready'))
     );

  return jsonb_build_object(
    'synced',n,
    'reactivated',reactivated,
    'pending',(select count(*) from public.contentflow_tool_execution_queue where project_key=p_project_key and state='pending'),
    'failed_held',(select count(*) from public.contentflow_tool_execution_queue where project_key=p_project_key and state='failed')
  );
end;
$$;

create or replace function public.contentflow_claim_tool_execution_task(p_project_key text default 'contentflow')
returns table(queue_id bigint, backlog_task_id bigint, task_key text, title text, description text, acceptance_criteria text, task_type text, claim_token uuid)
language plpgsql security definer
set search_path to 'public'
as $$
declare qid bigint; bid bigint; tok uuid:=gen_random_uuid();
begin
  select q.id,b.id into qid,bid
  from public.contentflow_tool_execution_queue q
  join public.contentflow_build_backlog b on b.id=q.backlog_task_id
  where q.project_key=p_project_key
    and q.state='pending'
    and b.status in ('blocked','ready')
    and b.execution_lane='tool_executor'
    and not exists(
      select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value)
      where not exists(
        select 1 from public.contentflow_build_backlog x
        where x.project_key=b.project_key and x.task_key=d.value and x.status='completed'
      )
    )
  order by public.contentflow_dependency_impact_score(b.project_key,b.task_key) desc,b.priority desc,b.id asc
  for update of q,b skip locked limit 1;

  if qid is null then return; end if;
  update public.contentflow_tool_execution_queue
     set state='claimed',claim_token=tok,claimed_at=now(),attempts=attempts+1,updated_at=now()
   where id=qid and state='pending';
  if not found then return; end if;

  update public.contentflow_build_backlog
     set status='running',updated_at=now()
   where id=bid and status in ('blocked','ready') and execution_lane='tool_executor';
  if not found then
    update public.contentflow_tool_execution_queue set state='blocked',claim_token=null,updated_at=now() where id=qid and claim_token=tok;
    return;
  end if;

  return query
    select q.id,b.id,b.task_key,b.title,b.description,b.acceptance_criteria,b.task_type,tok
    from public.contentflow_tool_execution_queue q
    join public.contentflow_build_backlog b on b.id=q.backlog_task_id
    where q.id=qid and q.claim_token=tok;
end;
$$;

create or replace function public.contentflow_finish_tool_execution_task(
  p_queue_id bigint,
  p_claim_token uuid,
  p_success boolean,
  p_evidence jsonb default '{}'::jsonb,
  p_error text default null
) returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare bid bigint; tkey text; is_evidence boolean:=false;
begin
  select backlog_task_id,task_key into bid,tkey
  from public.contentflow_tool_execution_queue
  where id=p_queue_id and state='claimed' and claim_token=p_claim_token
  for update;
  if bid is null then return jsonb_build_object('ok',false,'reason','fenced_out'); end if;

  select (epic='evidence_first' or completion_phase='evidence_required') into is_evidence
  from public.contentflow_build_backlog where id=bid for update;

  update public.contentflow_tool_execution_queue
     set state=case when p_success then 'completed' else 'failed' end,
         completed_at=case when p_success then now() else null end,
         last_error=p_error,evidence=coalesce(p_evidence,'{}'::jsonb),updated_at=now()
   where id=p_queue_id and state='claimed' and claim_token=p_claim_token;
  if not found then return jsonb_build_object('ok',false,'reason','fenced_out'); end if;

  if p_success then
    perform public.contentflow_clear_retry_after_repair(tkey);
    update public.contentflow_build_backlog
       set runtime_verified=true,runtime_verified_at=now(),
           runtime_evidence=coalesce(runtime_evidence,'{}'::jsonb)||coalesce(p_evidence,'{}'::jsonb),
           status=case when is_evidence then 'completed' else 'ready' end,
           quality_score=case when is_evidence then 100 else quality_score end,
           completion_phase=case when is_evidence then 'evidence_verified' else completion_phase end,
           next_eligible_at=case when is_evidence then next_eligible_at else now() end,
           updated_at=now()
     where id=bid and status='running' and execution_lane='tool_executor';
  else
    -- Fail closed: no false completion, no blind loop.
    update public.contentflow_build_backlog
       set status='blocked',updated_at=now()
     where id=bid and status='running' and execution_lane='tool_executor';
  end if;

  return jsonb_build_object('ok',true,'task_key',tkey,'success',p_success,'evidence_task',is_evidence);
end;
$$;
