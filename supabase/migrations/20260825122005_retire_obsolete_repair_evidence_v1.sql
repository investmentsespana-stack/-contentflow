update public.contentflow_build_backlog b
set status='deferred',blocked_reason='OBSOLETE_REPAIR_EVIDENCE_NO_ACTIVE_REQUIREMENT',next_eligible_at=null,selected_model=null,workflow_state='obsolete',completion_phase='obsolete',updated_at=now()
where b.project_key='contentflow' and b.status='verification_required' and b.task_key like 'repair_evidence_req_%'
  and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete');

update public.contentflow_builder_runs r
set status='deferred',finished_at=coalesce(finished_at,now()),error='OBSOLETE_REPAIR_EVIDENCE_NO_ACTIVE_REQUIREMENT'
where r.backlog_task_id in (select b.id from public.contentflow_build_backlog b where b.project_key='contentflow' and b.task_key like 'repair_evidence_req_%' and b.workflow_state='obsolete' and b.completion_phase='obsolete')
  and r.status='verification_required';
