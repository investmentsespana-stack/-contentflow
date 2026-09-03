create or replace function public.contentflow_reconcile_preproduction_evidence_stall_v1(p_project_key text default 'agent-academy-platform-v1')
returns jsonb
language plpgsql
security definer
set search_path to 'public','pg_temp'
as $$
declare v_count int:=0;
begin
  with candidates as (
    select b.id as backlog_id,r.id as run_id
    from public.contentflow_build_backlog b
    join public.contentflow_builder_runs r on r.backlog_task_id=b.id
    left join public.contentflow_review_work_queue q on q.builder_run_id=r.id
    where b.project_key=p_project_key
      and b.status='verification_required'
      and r.status='verification_required'
      and coalesce(r.review_approved,false)=true
      and q.state='done'
      and coalesce(b.workflow_contract->>'deliverable_scope','')='verified_evidence_preproduction_only'
      and coalesce(b.workflow_contract->>'runtime_media_claim_allowed','false')='false'
      and coalesce(r.result,b.result,'') like '%NO_VERIFIED_EXTERNAL_EVIDENCE%'
      and coalesce(r.result,b.result,'') like '%NO_DEPENDENCIES%'
      and coalesce(r.result,b.result,'') like '%NO_DIRECT_RUNTIME_SNAPSHOT%'
  ), upd_runs as (
    update public.contentflow_builder_runs r
       set status='failed',finished_at=coalesce(finished_at,now()),error='VERIFIED_SOURCE_EVIDENCE_REQUIRED'
      from candidates c where r.id=c.run_id returning r.id
  )
  update public.contentflow_build_backlog b
     set status='blocked',blocked_reason='VERIFIED_SOURCE_EVIDENCE_REQUIRED',completion_phase='evidence_required',updated_at=now()
    from candidates c where b.id=c.backlog_id;
  get diagnostics v_count=row_count;
  if v_count>0 then
    insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
    values(p_project_key,'preproduction_evidence_stall_reconcile','director_core','evidence_fail_closed','blocked_missing_verified_source',false,
      format('reconciled=%s; rule=artifact explicitly declares no external evidence, no dependencies, no runtime snapshot while acceptance requires evidence-backed preproduction',v_count),now());
  end if;
  return jsonb_build_object('ok',true,'project_key',p_project_key,'reconciled',v_count,'architecture','PREPRODUCTION_EVIDENCE_FAIL_CLOSED_V1');
end $$;

select cron.unschedule(jobid) from cron.job where jobname='academy-preproduction-evidence-reconcile-5m';
select cron.schedule('academy-preproduction-evidence-reconcile-5m','*/5 * * * *',$$select public.contentflow_reconcile_preproduction_evidence_stall_v1('agent-academy-platform-v1');$$);
