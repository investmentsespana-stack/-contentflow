-- EVIDENCE_VERIFIER_PREFLIGHT_GATE_V1
create or replace function public.contentflow_evidence_verifier_preflight(p_project_key text,p_evidence_task_key text)
returns boolean
language plpgsql stable security definer
set search_path to 'public'
as $$
declare
  er record; st record; ev jsonb:='[]'::jsonb; rt text:=''; evt text:=''; non_generic int:=0; cls text;
begin
  select * into er from public.contentflow_evidence_requirements
   where project_key=p_project_key and evidence_task_key=p_evidence_task_key
   order by id desc limit 1;
  if er.id is null then return false; end if;
  select runtime_verified,coalesce(runtime_evidence,'{}'::jsonb) runtime_evidence into st
    from public.contentflow_build_backlog where id=er.backlog_task_id;
  select coalesce(jsonb_agg(jsonb_build_object('event_type',l.event_type,'payload',l.payload)),'[]'::jsonb),
         count(*) filter(where l.event_type not in ('claimed','runner_started','runner_v2_started','runner_v4_started','runner_v5_started','artifact_generated','judge_completed','runner_completed','owner_finalized'))
    into ev,non_generic from public.contentflow_runtime_event_ledger l where l.builder_run_id=er.source_run_id;
  rt:=lower(coalesce(st.runtime_evidence,'{}'::jsonb)::text); evt:=lower(ev::text); cls:=coalesce(er.requirement_class,'unknown');
  if cls in ('runtime_evidence','persistence_integration') then return coalesce(st.runtime_verified,false) and (coalesce(st.runtime_evidence,'{}'::jsonb)<>'{}'::jsonb or non_generic>0); end if;
  if cls='runtime_test' then return (rt||evt) ~ '(test|assert|integration|ci_)'; end if;
  if cls='static_analysis' then return (rt||evt) ~ '(static|lint|mypy|scan)'; end if;
  if cls='external_approval' then return (rt||evt) ~ '(approval|approved_by)'; end if;
  if cls='source_contract' then return coalesce(st.runtime_verified,false) and (rt||evt) ~ 'source' and coalesce(st.runtime_evidence,'{}'::jsonb)<>'{}'::jsonb; end if;
  return false;
end;
$$;

create or replace function public.contentflow_sync_tool_execution_queue(p_project_key text default 'contentflow')
returns jsonb
language plpgsql security definer
set search_path to 'public'
as $$
declare n int:=0; reactivated int:=0; quarantined int:=0; held int:=0; recovered_failed int:=0;
begin
  insert into public.contentflow_tool_execution_queue(project_key,backlog_task_id,task_key,state,updated_at)
  select b.project_key,b.id,b.task_key,'pending',now() from public.contentflow_build_backlog b
  where b.project_key=p_project_key and b.execution_lane='tool_executor' and b.status in ('blocked','ready')
    and public.contentflow_evidence_verifier_preflight(p_project_key,b.task_key)
    and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.value and x.status='completed'))
  on conflict(project_key,backlog_task_id) do nothing;
  get diagnostics n=row_count;

  update public.contentflow_tool_execution_queue q set state='pending',last_error=null,updated_at=now()
  where q.project_key=p_project_key and q.state='blocked'
    and public.contentflow_evidence_verifier_preflight(p_project_key,q.task_key)
    and exists(select 1 from public.contentflow_build_backlog b where b.id=q.backlog_task_id and b.execution_lane='tool_executor' and b.status in ('blocked','ready') and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.value and x.status='completed')));
  get diagnostics reactivated=row_count;

  -- A previous EVIDENCE_NOT_AVAILABLE failure may retry exactly when new deterministic evidence becomes available.
  update public.contentflow_tool_execution_queue q set state='pending',last_error=null,updated_at=now()
  where q.project_key=p_project_key and q.state='failed' and coalesce(q.last_error,'') like 'EVIDENCE_NOT_AVAILABLE:%'
    and public.contentflow_evidence_verifier_preflight(p_project_key,q.task_key)
    and exists(select 1 from public.contentflow_build_backlog b where b.id=q.backlog_task_id and b.execution_lane='tool_executor' and b.status in ('blocked','ready'));
  get diagnostics recovered_failed=row_count;

  update public.contentflow_tool_execution_queue q set state='blocked',claim_token=null,claimed_at=null,updated_at=now(),last_error=coalesce(q.last_error,'')||case when coalesce(q.last_error,'')='' then '' else ' | ' end||'QUARANTINED_OFF_LANE_STALE_CLAIM'
  where q.project_key=p_project_key and q.state='claimed' and exists(select 1 from public.contentflow_build_backlog b where b.id=q.backlog_task_id and b.execution_lane<>'tool_executor' and b.status<>'running');
  get diagnostics quarantined=row_count;

  -- Hold verifier tasks that cannot possibly pass yet; do not burn attempts.
  update public.contentflow_tool_execution_queue q set state='blocked',last_error='WAITING_FOR_EVIDENCE_PRODUCER',updated_at=now()
  where q.project_key=p_project_key and q.state='pending'
    and exists(select 1 from public.contentflow_build_backlog b where b.id=q.backlog_task_id and b.execution_lane='tool_executor')
    and not public.contentflow_evidence_verifier_preflight(p_project_key,q.task_key);
  get diagnostics held=row_count;

  update public.contentflow_tool_execution_queue q set state='blocked',updated_at=now()
  where q.project_key=p_project_key and q.state='pending'
    and exists(select 1 from public.contentflow_build_backlog b where b.id=q.backlog_task_id and (b.execution_lane<>'tool_executor' or b.status not in ('blocked','ready')));

  return jsonb_build_object('synced',n,'reactivated',reactivated,'recovered_failed',recovered_failed,'quarantined_claims',quarantined,'held_for_producer',held,'pending',(select count(*) from public.contentflow_tool_execution_queue where project_key=p_project_key and state='pending'),'failed_held',(select count(*) from public.contentflow_tool_execution_queue where project_key=p_project_key and state='failed'));
end;
$$;

create or replace function public.contentflow_claim_tool_execution_task(p_project_key text default 'contentflow')
returns table(queue_id bigint, backlog_task_id bigint, task_key text, title text, description text, acceptance_criteria text, task_type text, claim_token uuid)
language plpgsql security definer
set search_path to 'public'
as $$
declare qid bigint; bid bigint; tok uuid:=gen_random_uuid();
begin
  select q.id,b.id into qid,bid from public.contentflow_tool_execution_queue q join public.contentflow_build_backlog b on b.id=q.backlog_task_id
  where q.project_key=p_project_key and q.state='pending' and b.status in ('blocked','ready') and b.execution_lane='tool_executor'
    and public.contentflow_evidence_verifier_preflight(p_project_key,q.task_key)
    and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.value and x.status='completed'))
  order by public.contentflow_dependency_impact_score(b.project_key,b.task_key) desc,b.priority desc,b.id asc for update of q,b skip locked limit 1;
  if qid is null then return; end if;
  update public.contentflow_tool_execution_queue set state='claimed',claim_token=tok,claimed_at=now(),attempts=attempts+1,updated_at=now() where id=qid and state='pending';
  if not found then return; end if;
  update public.contentflow_build_backlog set status='running',updated_at=now() where id=bid and status in ('blocked','ready') and execution_lane='tool_executor';
  if not found then update public.contentflow_tool_execution_queue set state='blocked',claim_token=null,updated_at=now() where id=qid and claim_token=tok; return; end if;
  return query select q.id,b.id,b.task_key,b.title,b.description,b.acceptance_criteria,b.task_type,tok from public.contentflow_tool_execution_queue q join public.contentflow_build_backlog b on b.id=q.backlog_task_id where q.id=qid and q.claim_token=tok;
end;
$$;
