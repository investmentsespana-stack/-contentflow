create or replace function public.contentflow_completion_evidence_mode_v3(p_task_key text,p_title text,p_description text,p_acceptance text)
returns text language sql immutable set search_path='public' as $$
with s as (select lower(coalesce(p_task_key,'')||' '||coalesce(p_title,'')||' '||coalesce(p_description,'')||' '||coalesce(p_acceptance,'')) txt)
select case
  when lower(coalesce(p_task_key,'')) like 'repair_evidence_req_%' or lower(coalesce(p_title,'')) like 'produce real evidence%' then 'evidence_activity'
  when txt ~ '(manual approval|human approval|owner approval|security team approval|sign.?off|authorization required)' then 'external_approval'
  when txt ~ '(version-controlled|version control|commit sha|commit hash|repository|repo link|file path|merged with sha|merged into|yaml file|json schema|/patterns/|\.yaml|\.json|\.md)' and txt ~ '(runtime|integration test|test execution|curl|http [245][0-9][0-9]|endpoint|middleware is invoked|runtime trace|runtime log)' then 'repo_and_runtime_test'
  when txt ~ '(runtime trace|runtime log|persisted runtime|database record|read.?back|evidence store|durable storage)' then 'runtime_persistence'
  when txt ~ '(integration test|unit test|test suite|test corpus|test execution|curl|dev environment|endpoint returns|http 403|http 404|http 410|middleware is invoked|actual execution|required.*runtime|runtime verification)' then 'runtime_test'
  when txt ~ '(static analysis|lint|mypy|scanner|scan report|irreversible operation|machine-readable report.*line number)' then 'static_analysis'
  when txt ~ '(version-controlled|version control|commit sha|commit hash|repository|repo link|file path|merged with sha|merged into|yaml file|json schema|/patterns/|\.yaml|\.json|\.md)' then 'repo_commit_or_file'
  when txt ~ '(deploy|deployment|staging|production trace)' then 'deployment_trace'
  when txt ~ '(specification includes|protocol spec|document .*specif|decision record .*document|mapping section|schema structure|validation rules|contract semantics|architecture contract)' then 'artifact_review_only'
  else 'unclassified' end from s;
$$;

create or replace function public.contentflow_reconcile_completion_evidence_v3(p_project_key text default 'contentflow',p_limit integer default 100)
returns jsonb language plpgsql security definer set search_path='public' as $$
declare x record; v_mode text; v_req_class text; v_fp text; v_evidence_key text; v_req_id bigint; v_created int:=0; v_rerouted int:=0; v_artifact_completed int:=0; v_promoted int:=0; v_unclassified int:=0; v_incidents int:=0; v_child record; v_v jsonb;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if;

  update public.contentflow_build_backlog b set execution_lane='evidence_producer',completion_phase='evidence_required',status='ready',selected_model=null,next_eligible_at=now(),blocked_reason=null,
         workflow_contract=coalesce(b.workflow_contract,'{}'::jsonb)||jsonb_build_object('contract_version','3','artifact_kind','evidence_activity','runtime_required',true,'evidence_policy','required','completion_gate','runtime_evidence_verified','retry_policy','typed_transient_only'),updated_at=now()
  where b.project_key=p_project_key and b.status='verification_required' and (b.task_key like 'repair_evidence_req_%' or lower(b.title) like 'produce real evidence%')
    and exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and er.evidence_task_key=b.task_key and er.status<>'obsolete');
  get diagnostics v_rerouted=row_count;

  for x in
    select b.*,r.id run_id,r.quality_score run_quality,r.review_approved,r.result run_result
    from public.contentflow_build_backlog b
    join lateral (select z.* from public.contentflow_builder_runs z where z.backlog_task_id=b.id order by z.id desc limit 1) r on true
    where b.project_key=p_project_key and b.status='verification_required'
      and b.task_key not like 'repair_evidence_req_%' and lower(b.title) not like 'produce real evidence%'
      and coalesce(r.review_approved,false)=true and r.result is not null and length(trim(r.result))>=40
    order by b.priority desc,b.id asc
    limit greatest(1,least(coalesce(p_limit,100),300))
  loop
    v_mode:=public.contentflow_completion_evidence_mode_v3(x.task_key,x.title,x.description,x.acceptance_criteria);
    if v_mode='artifact_review_only' then
      update public.contentflow_build_backlog set workflow_contract=coalesce(workflow_contract,'{}'::jsonb)||jsonb_build_object('contract_version','3','artifact_kind','reviewed_artifact','evidence_mode',v_mode,'runtime_required',false,'evidence_policy','rara_review','completion_gate','rara_approved'),updated_at=now() where id=x.id;
      update public.contentflow_builder_runs set status='completed',finished_at=coalesce(finished_at,now()),error=null where id=x.run_id and status='verification_required' and review_approved=true;
      update public.contentflow_build_backlog set status='completed',quality_score=greatest(coalesce(quality_score,0),coalesce(x.run_quality,0)),result=coalesce(result,x.run_result),completion_phase='artifact_approved',blocked_reason=null,next_eligible_at=null,updated_at=now() where id=x.id and status='verification_required';
      if found then v_artifact_completed:=v_artifact_completed+1; end if;
      continue;
    elsif v_mode='unclassified' or v_mode in ('external_approval','repo_and_runtime_test','deployment_trace') then
      v_unclassified:=v_unclassified+1;
      continue;
    end if;

    v_req_class:=case v_mode when 'repo_commit_or_file' then 'repo_artifact' when 'runtime_test' then 'runtime_test' when 'runtime_persistence' then 'runtime_evidence' when 'static_analysis' then 'static_analysis' else 'source_contract' end;
    v_fp:=md5(x.project_key||'|'||x.task_key||'|'||x.run_id::text||'|'||x.artifact_version::text||'|'||v_mode);
    v_evidence_key:='verify_'||left(regexp_replace(x.task_key,'[^a-zA-Z0-9_]+','','g'),64)||'_'||left(v_fp,10);
    select er.id into v_req_id from public.contentflow_evidence_requirements er where er.project_key=x.project_key and er.backlog_task_id=x.id and er.requirement_fingerprint=v_fp and er.status<>'obsolete' order by er.id desc limit 1;
    if v_req_id is null then
      insert into public.contentflow_evidence_requirements(project_key,backlog_task_id,source_run_id,task_key,requirement_class,requirement_fingerprint,requirement_text,evidence_task_key,status,updated_at)
      values(x.project_key,x.id,x.run_id,x.task_key,v_req_class,v_fp,'Completion evidence mode='||v_mode||'. Verify acceptance criteria with real evidence: '||left(coalesce(x.acceptance_criteria,''),5000),v_evidence_key,'task_created',now()) returning id into v_req_id;
      v_created:=v_created+1;
    end if;
    if not exists(select 1 from public.contentflow_build_backlog e where e.project_key=x.project_key and e.task_key=v_evidence_key) then
      insert into public.contentflow_build_backlog(project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,acceptance_criteria,quality_score,next_eligible_at,completion_phase,execution_lane,source_run_id,workflow_contract,workflow_state)
      values(x.project_key,'evidence_first',v_evidence_key,'Verification activity: '||left(x.title,160),'Produce deterministic, persisted evidence for source task '||x.task_key||' and source run '||x.run_id||'. Evidence mode='||v_mode||'. Do not substitute prose for execution evidence.','code',x.stage,'[]'::jsonb,'evidence-first','ready',greatest(coalesce(x.priority,0),100),'Evidence must be real, correlated to source_run_id='||x.run_id||', persisted, independently checkable, and satisfy: '||left(coalesce(x.acceptance_criteria,''),4000),0,now(),'evidence_required','evidence_producer',x.run_id,jsonb_build_object('contract_version','3','artifact_kind','verification_activity','source_task_key',x.task_key,'source_builder_run_id',x.run_id,'evidence_mode',v_mode,'runtime_required',true,'evidence_policy','required','completion_gate','runtime_evidence_verified','retry_policy','typed_transient_only'),'artifact_pending');
    end if;
    update public.contentflow_build_backlog set workflow_contract=coalesce(workflow_contract,'{}'::jsonb)||jsonb_build_object('contract_version','3','evidence_mode',v_mode,'runtime_required',v_mode not in ('repo_commit_or_file','static_analysis'),'evidence_policy','required','verification_requirement_id',v_req_id,'verification_task_key',v_evidence_key,'completion_gate','verified_evidence'),workflow_state='runtime_verification_wait',completion_phase='verification_required',updated_at=now() where id=x.id;

    select e.* into v_child from public.contentflow_build_backlog e where e.project_key=x.project_key and e.task_key=v_evidence_key order by e.id desc limit 1;
    if exists(select 1 from public.contentflow_evidence_requirements er where er.id=v_req_id and er.status='verified') and v_child.status='completed' and coalesce(v_child.runtime_evidence,'{}'::jsonb)<>'{}'::jsonb then
      if v_mode in ('repo_commit_or_file','static_analysis') then
        update public.contentflow_builder_runs set status='completed',finished_at=coalesce(finished_at,now()),error=null where id=x.run_id and status='verification_required' and review_approved=true;
        update public.contentflow_build_backlog set status='completed',completion_phase='artifact_verified',quality_score=greatest(coalesce(quality_score,0),coalesce(x.run_quality,0)),result=coalesce(result,x.run_result),runtime_evidence=coalesce(runtime_evidence,'{}'::jsonb)||jsonb_build_object('completion_verification',v_child.runtime_evidence),blocked_reason=null,next_eligible_at=null,updated_at=now() where id=x.id and status='verification_required';
        if found then v_promoted:=v_promoted+1; end if;
      else
        v_v:=public.contentflow_record_runtime_verification(x.run_id,'completion_evidence_v3_'||v_mode,true,v_child.runtime_evidence,'completion_evidence_controller_v3');
        if coalesce((v_v->>'promoted_completed')::boolean,false) then v_promoted:=v_promoted+1; end if;
      end if;
    end if;
  end loop;

  perform public.contentflow_sync_tool_execution_queue(p_project_key);
  if v_unclassified>0 and not exists(select 1 from public.director_repair_incidents where project_key=p_project_key and error_fingerprint='completion_evidence_unclassified:v3' and status in ('open','analyzing','repairing','validating','needs_help')) then
    insert into public.director_repair_incidents(project_key,component,error_class,error_fingerprint,symptom,evidence,risk_level,status,max_attempts,requires_human,root_cause,proposed_action)
    values(p_project_key,'completion_control','completion_evidence_unclassified','completion_evidence_unclassified:v3','Reviewed artifacts require verification but their evidence modality is composite, deployment-bound, external-authority, or unclassified',jsonb_build_object('count',v_unclassified),'medium','open',3,false,'Completion contract lacks a single deterministic evidence modality','Decompose composite verification into explicit activities or register a task-specific producer');
    get diagnostics v_incidents=row_count;
  end if;
  return jsonb_build_object('architecture','COMPLETION_EVIDENCE_CONTRACT_V3','evidence_tasks_rerouted',v_rerouted,'requirements_created',v_created,'artifact_review_only_completed',v_artifact_completed,'verified_promoted',v_promoted,'unclassified_or_composite',v_unclassified,'incident_created',v_incidents);
end $$;
revoke all on function public.contentflow_reconcile_completion_evidence_v3(text,integer) from public,anon,authenticated;
grant execute on function public.contentflow_reconcile_completion_evidence_v3(text,integer) to service_role;
