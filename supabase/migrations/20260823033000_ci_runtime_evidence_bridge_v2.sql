create or replace function public.contentflow_record_ci_requirement_evidence(
  p_requirement_id bigint,
  p_builder_run_id bigint,
  p_task_key text,
  p_test_profile text,
  p_commit_sha text,
  p_workflow_run_id text,
  p_payload jsonb
) returns jsonb
language plpgsql
security definer
set search_path='public'
as $$
declare er public.contentflow_evidence_requirements%rowtype; v_hash text; v_id bigint; v_key text; v_type text;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then raise exception 'privileged_ci_channel_required'; end if;
  if p_payload is null or p_payload='{}'::jsonb or coalesce((p_payload->>'passed')::boolean,false) is not true then raise exception 'passing_nonempty_payload_required'; end if;
  if coalesce(trim(p_test_profile),'')='' or coalesce(trim(p_commit_sha),'')='' or coalesce(trim(p_workflow_run_id),'')='' then raise exception 'ci_identity_required'; end if;
  select * into er from public.contentflow_evidence_requirements where id=p_requirement_id for update;
  if not found then raise exception 'requirement_not_found'; end if;
  if er.project_key<>'contentflow' then raise exception 'wrong_project'; end if;
  if er.source_run_id is distinct from p_builder_run_id or er.task_key is distinct from p_task_key then raise exception 'requirement_correlation_mismatch'; end if;
  if er.status='verified' then return jsonb_build_object('ok',true,'already_verified',true,'requirement_id',er.id); end if;
  if p_test_profile not in ('evidence-persistence','runtime-test','static-analysis','source-contract') then raise exception 'unsupported_test_profile'; end if;
  v_type:=case when p_test_profile='static-analysis' then 'static_analysis' when p_test_profile='source-contract' then 'source_contract' else 'runtime_test' end;
  v_key:='ci:'||p_test_profile||':requirement:'||er.id::text||':run:'||p_workflow_run_id;
  v_hash:=encode(extensions.digest(convert_to(p_payload::text,'UTF8'),'sha256'::text),'hex');
  insert into public.contentflow_runtime_evidence_ledger(project_key,backlog_task_id,builder_run_id,task_key,evidence_type,evidence_key,payload,payload_sha256,producer,observed_at,requirement_id)
  values(er.project_key,er.backlog_task_id,er.source_run_id,er.task_key,v_type,
    v_key,
    p_payload||jsonb_build_object('requirement_id',er.id,'test_profile',p_test_profile,'commit_sha',p_commit_sha,'workflow_run_id',p_workflow_run_id,'source_run_id',er.source_run_id,'source_task_key',er.task_key),
    v_hash,'github-actions-ci',now(),er.id)
  on conflict(project_key,builder_run_id,evidence_key,payload_sha256) do nothing
  returning id into v_id;
  if v_id is null then select id into v_id from public.contentflow_runtime_evidence_ledger where project_key=er.project_key and builder_run_id=er.source_run_id and evidence_key=v_key order by id desc limit 1; end if;
  return jsonb_build_object('ok',true,'evidence_id',v_id,'requirement_id',er.id,'sha256',v_hash);
end $$;
revoke all on function public.contentflow_record_ci_requirement_evidence(bigint,bigint,text,text,text,text,jsonb) from public, anon, authenticated;
grant execute on function public.contentflow_record_ci_requirement_evidence(bigint,bigint,text,text,text,text,jsonb) to service_role, postgres;

create or replace function public.contentflow_reconcile_ci_requirement_evidence(p_project_key text default 'contentflow') returns jsonb
language plpgsql
security definer
set search_path='public'
as $$
declare v_verified int:=0; v_completed int:=0; v_reopened int:=0;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then raise exception 'privileged_channel_required'; end if;
  with eligible as (
    select er.id,er.evidence_task_key,l.id evidence_id,l.evidence_type,l.evidence_key,l.payload,l.payload_sha256,l.producer,l.observed_at
    from public.contentflow_evidence_requirements er
    join lateral (
      select x.* from public.contentflow_runtime_evidence_ledger x
      where x.project_key=er.project_key and x.requirement_id=er.id and x.builder_run_id=er.source_run_id and x.task_key=er.task_key
        and x.producer='github-actions-ci' and coalesce((x.payload->>'passed')::boolean,false)=true
        and (
          (er.requirement_class='runtime_test' and x.evidence_type='runtime_test') or
          (er.requirement_class='static_analysis' and x.evidence_type='static_analysis') or
          (er.requirement_class='source_contract' and x.evidence_type='source_contract') or
          (er.requirement_class in ('runtime_evidence','persistence_integration') and x.evidence_type='runtime_test')
        )
      order by x.id desc limit 1
    ) l on true
    where er.project_key=p_project_key and er.status='task_created'
  )
  update public.contentflow_evidence_requirements er set status='verified',verified_at=now(),updated_at=now(),
    evidence_ref=jsonb_build_object('architecture','CI_RUNTIME_EVIDENCE_BRIDGE_V2','evidence_id',e.evidence_id,'evidence_type',e.evidence_type,'evidence_key',e.evidence_key,'sha256',e.payload_sha256,'producer',e.producer,'observed_at',e.observed_at,'payload',e.payload)
  from eligible e where er.id=e.id;
  get diagnostics v_verified=row_count;

  update public.contentflow_build_backlog b set status='completed',runtime_verified=true,
    runtime_evidence=coalesce(er.evidence_ref,'{}'::jsonb),quality_score=greatest(coalesce(b.quality_score,0),100),completion_phase='evidence_verified',updated_at=now()
  from public.contentflow_evidence_requirements er
  where er.project_key=p_project_key and er.status='verified' and b.project_key=er.project_key and b.task_key=er.evidence_task_key and b.status<>'completed';
  get diagnostics v_completed=row_count;

  update public.contentflow_build_backlog b set status='ready',next_eligible_at=now(),completion_phase='evidence_verified',updated_at=now()
  where b.project_key=p_project_key and b.status='blocked' and b.completion_phase='waiting_for_evidence'
    and not exists(select 1 from public.contentflow_evidence_requirements er where er.backlog_task_id=b.id and er.status<>'verified')
    and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog dep where dep.project_key=b.project_key and dep.task_key=d.value and dep.status='completed'));
  get diagnostics v_reopened=row_count;
  return jsonb_build_object('architecture','CI_RUNTIME_EVIDENCE_BRIDGE_V2','requirements_verified',v_verified,'evidence_tasks_completed',v_completed,'originals_reopened',v_reopened);
end $$;
revoke all on function public.contentflow_reconcile_ci_requirement_evidence(text) from public, anon, authenticated;
grant execute on function public.contentflow_reconcile_ci_requirement_evidence(text) to service_role, postgres;
