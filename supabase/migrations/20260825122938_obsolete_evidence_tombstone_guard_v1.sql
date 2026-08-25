create or replace function public.contentflow_obsolete_evidence_tombstone_guard_v1()
returns trigger language plpgsql set search_path='public' as $$
begin
  if new.project_key='contentflow'
     and new.task_key like 'repair_evidence_req_%'
     and not exists(
       select 1 from public.contentflow_evidence_requirements er
       where er.project_key=new.project_key
         and (er.backlog_task_id=new.id or er.evidence_task_key=new.task_key)
         and er.status<>'obsolete'
     ) then
    new.status:='deferred';
    new.workflow_state:='obsolete';
    new.completion_phase:='obsolete';
    new.blocked_reason:='OBSOLETE_REPAIR_EVIDENCE_NO_ACTIVE_REQUIREMENT';
    new.next_eligible_at:=null;
    new.selected_model:=null;
  end if;
  return new;
end $$;

drop trigger if exists zz_contentflow_obsolete_evidence_tombstone on public.contentflow_build_backlog;
create trigger zz_contentflow_obsolete_evidence_tombstone
before update of status,workflow_state,completion_phase,blocked_reason,next_eligible_at,selected_model
on public.contentflow_build_backlog
for each row execute function public.contentflow_obsolete_evidence_tombstone_guard_v1();

create or replace function public.contentflow_retire_obsolete_evidence_tombstones_v1(p_project_key text default 'contentflow')
returns jsonb language plpgsql security definer set search_path='public' as $$
declare v_runs int:=0; v_tasks int:=0; v_workers int:=0; v_slots int:=0; v_reviews int:=0; v_retry int:=0;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if;

  update public.contentflow_builder_runs r
     set status='deferred',finished_at=coalesce(r.finished_at,now()),error='OBSOLETE_REPAIR_EVIDENCE_TOMBSTONED',
         lease_revoked_at=coalesce(r.lease_revoked_at,now()),lease_generation=r.lease_generation+1,
         activity_phase=null,activity_deadline_at=null,heartbeat_deadline_at=null
   where r.project_key=p_project_key and r.status in ('claimed','running','review_required','verification_required')
     and exists(
       select 1 from public.contentflow_build_backlog b
       where b.id=r.backlog_task_id and b.task_key like 'repair_evidence_req_%'
         and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete')
     );
  get diagnostics v_runs=row_count;

  update public.contentflow_review_work_queue q
     set state='done',claim_token=null,claimed_at=null,last_error='OBSOLETE_REPAIR_EVIDENCE_TOMBSTONED',updated_at=now()
   where q.state in ('pending','claimed') and exists(
     select 1 from public.contentflow_builder_runs r join public.contentflow_build_backlog b on b.id=r.backlog_task_id
     where r.id=q.builder_run_id and b.project_key=p_project_key and b.task_key like 'repair_evidence_req_%'
       and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete')
   );
  get diagnostics v_reviews=row_count;

  update public.contentflow_retry_state rs set circuit_state='closed',attempt_count=0,next_retry_at=null,circuit_open_until=null,updated_at=now()
  from public.contentflow_build_backlog b
  where rs.backlog_task_id=b.id and b.project_key=p_project_key and b.task_key like 'repair_evidence_req_%'
    and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete');
  get diagnostics v_retry=row_count;

  update public.director_worker_queue q set status='ready',current_task_key=null,last_outcome='obsolete_evidence_tombstoned',updated_at=now()
  where q.current_task_key in (
    select b.task_key from public.contentflow_build_backlog b where b.project_key=p_project_key and b.task_key like 'repair_evidence_req_%'
      and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete')
  );
  get diagnostics v_workers=row_count;

  update public.contentflow_nexo_slots s set released_at=coalesce(s.released_at,now()),release_reason=coalesce(s.release_reason,'obsolete_evidence_tombstoned')
  where s.released_at is null and s.task_key in (
    select b.task_key from public.contentflow_build_backlog b where b.project_key=p_project_key and b.task_key like 'repair_evidence_req_%'
      and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete')
  );
  get diagnostics v_slots=row_count;

  update public.contentflow_build_backlog b
     set status='deferred',workflow_state='obsolete',completion_phase='obsolete',blocked_reason='OBSOLETE_REPAIR_EVIDENCE_NO_ACTIVE_REQUIREMENT',next_eligible_at=null,selected_model=null,updated_at=now()
   where b.project_key=p_project_key and b.task_key like 'repair_evidence_req_%'
     and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and (er.backlog_task_id=b.id or er.evidence_task_key=b.task_key) and er.status<>'obsolete')
     and (b.status<>'deferred' or b.workflow_state<>'obsolete' or b.completion_phase<>'obsolete' or coalesce(b.blocked_reason,'')<>'OBSOLETE_REPAIR_EVIDENCE_NO_ACTIVE_REQUIREMENT' or b.next_eligible_at is not null or b.selected_model is not null);
  get diagnostics v_tasks=row_count;

  return jsonb_build_object('architecture','OBSOLETE_EVIDENCE_TOMBSTONE_GUARD_V1','runs_revoked',v_runs,'tasks_tombstoned',v_tasks,'workers_released',v_workers,'slots_released',v_slots,'reviews_closed',v_reviews,'retry_states_closed',v_retry);
end $$;
revoke all on function public.contentflow_retire_obsolete_evidence_tombstones_v1(text) from public,anon,authenticated;
grant execute on function public.contentflow_retire_obsolete_evidence_tombstones_v1(text) to service_role;
