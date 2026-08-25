-- Reconstructed from live production catalog on 2026-08-25.
create or replace function public.contentflow_durable_contract_reconcile(p_project_key text default 'contentflow')
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare reopened int:=0; obsolete_evidence int:=0; deps_removed int:=0; incidents_resolved int:=0; rec record; rc int:=0;
begin
 if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if;
 update public.contentflow_evidence_requirements er set status='obsolete',updated_at=now() from public.contentflow_build_backlog b
 where er.backlog_task_id=b.id and b.project_key=p_project_key and (coalesce(b.workflow_contract,'{}'::jsonb) ? 'runtime_required' or coalesce(b.workflow_contract->>'contract_version','')<>'') and coalesce(b.workflow_contract->>'evidence_policy','declared_gaps_allowed')<>'required' and er.status in ('open','task_created');
 get diagnostics obsolete_evidence=row_count;
 for rec in select b.id,b.project_key,b.depends_on from public.contentflow_build_backlog b where b.project_key=p_project_key and (coalesce(b.workflow_contract,'{}'::jsonb) ? 'runtime_required' or coalesce(b.workflow_contract->>'contract_version','')<>'') and coalesce(b.workflow_contract->>'evidence_policy','declared_gaps_allowed')<>'required' loop
   update public.contentflow_build_backlog as t set depends_on=coalesce(t.depends_on,'[]'::jsonb)-e.task_key,updated_at=now() from public.contentflow_build_backlog as e
   where t.id=rec.id and e.project_key=rec.project_key and e.task_key in (select jsonb_array_elements_text(coalesce(rec.depends_on,'[]'::jsonb))) and (e.epic='evidence_first' or e.execution_lane in ('tool_executor','evidence_producer')) and e.status<>'completed';
   get diagnostics rc=row_count; deps_removed:=deps_removed+rc;
 end loop;
 update public.contentflow_build_backlog e set status='deferred',blocked_reason='OBSOLETE_BY_DURABLE_CONTRACT_V2',updated_at=now()
 where e.project_key=p_project_key and (e.epic='evidence_first' or e.execution_lane in ('tool_executor','evidence_producer')) and e.status in ('ready','planned','blocked') and exists(select 1 from public.contentflow_evidence_requirements er where er.evidence_task_key=e.task_key and er.status='obsolete');
 update public.contentflow_retry_state rs set circuit_state='closed',attempt_count=0,next_retry_at=null,circuit_open_until=null,updated_at=now() from public.contentflow_build_backlog b
 where rs.backlog_task_id=b.id and b.project_key=p_project_key and (coalesce(b.workflow_contract,'{}'::jsonb) ? 'runtime_required' or coalesce(b.workflow_contract->>'contract_version','')<>'') and b.workflow_state in ('patch_required','artifact_patch_required') and rs.circuit_state='open';
 update public.contentflow_build_backlog b set status=case when not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(dep) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.dep and x.status='completed')) then 'ready' else 'planned' end,blocked_reason=null,next_eligible_at=now(),selected_model=null,updated_at=now()
 where b.project_key=p_project_key and (coalesce(b.workflow_contract,'{}'::jsonb) ? 'runtime_required' or coalesce(b.workflow_contract->>'contract_version','')<>'') and b.workflow_state in ('patch_required','artifact_patch_required') and b.status in ('blocked','planned') and coalesce(b.blocked_reason,'')<>'REVIEW_PENDING';
 get diagnostics reopened=row_count;
 update public.director_repair_incidents i set status='resolved',requires_human=false,resolved_at=now(),updated_at=now(),outcome='superseded_by_durable_contract_v2',diagnosis='Legacy escalation contradicted explicit durable workflow contract',validation='contract_driven_reconciliation'
 where i.project_key=p_project_key and i.status in ('open','analyzing','repairing','validating','needs_help') and (i.error_class in ('progress_stall','durable_wait_unclassified','completion_evidence_unclassified') or (i.error_class='owner_required' and exists(select 1 from public.contentflow_build_backlog b where b.project_key=p_project_key and coalesce((b.workflow_contract->>'artifact_completion_independent_of_external_approval')::boolean,false))));
 get diagnostics incidents_resolved=row_count;
 return jsonb_build_object('architecture','DURABLE_TASK_STATE_MACHINE_V2','reopened_patch_tasks',reopened,'obsolete_false_evidence',obsolete_evidence,'legacy_evidence_edges_removed',deps_removed,'legacy_incidents_resolved',incidents_resolved);
end $function$;
revoke all on function public.contentflow_durable_contract_reconcile(text) from public,anon,authenticated;
grant execute on function public.contentflow_durable_contract_reconcile(text) to service_role;
