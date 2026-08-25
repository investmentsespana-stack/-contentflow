alter table public.contentflow_evidence_requirements drop constraint if exists contentflow_evidence_requirem_project_key_backlog_task_id_r_key;
create unique index if not exists uq_contentflow_evidence_requirement_active on public.contentflow_evidence_requirements(project_key,backlog_task_id,requirement_fingerprint) where status<>'obsolete';

create or replace function public.contentflow_reconcile_evidence_capability_queue(p_project_key text default 'contentflow')
returns jsonb language plpgsql security definer set search_path='public' as $$
declare held int:=0; released int:=0;
begin
 if coalesce(auth.role(),'') <> 'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if;
 update public.contentflow_tool_execution_queue q
 set state='blocked',claim_token=null,claimed_at=null,updated_at=now(),last_error='CAPABILITY_WAIT:'||coalesce(m.prerequisite,'unknown')
 from public.contentflow_build_backlog b
 left join public.contentflow_evidence_requirements er on er.project_key=b.project_key and er.evidence_task_key=b.task_key and er.status<>'obsolete'
 left join public.contentflow_evidence_capability_matrix m on m.requirement_id=er.id
 where q.project_key=p_project_key and q.backlog_task_id=b.id and q.state='pending'
   and (b.epic='evidence_first' or b.completion_phase='evidence_required')
   and not public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key);
 get diagnostics held=row_count;
 update public.contentflow_tool_execution_queue q
 set state='pending',last_error=null,claim_token=null,claimed_at=null,updated_at=now()
 from public.contentflow_build_backlog b
 where q.project_key=p_project_key and q.backlog_task_id=b.id and q.state='blocked'
   and q.last_error like 'CAPABILITY_WAIT:%'
   and public.contentflow_tool_execution_capability_ready(p_project_key,b.task_key);
 get diagnostics released=row_count;
 return jsonb_build_object('architecture','EVIDENCE_CAPABILITY_ADMISSION_V2','held',held,'released',released,'pending',(select count(*) from public.contentflow_tool_execution_queue where project_key=p_project_key and state='pending'),'capability_wait',(select count(*) from public.contentflow_tool_execution_queue where project_key=p_project_key and state='blocked' and last_error like 'CAPABILITY_WAIT:%'));
end $$;
