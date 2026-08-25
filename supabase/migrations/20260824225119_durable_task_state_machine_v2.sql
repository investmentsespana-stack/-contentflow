-- Reconstructed from live production catalog on 2026-08-25.
-- Canonical current-state bridge for the Durable Task State Machine V2 lineage.
-- Later historical checkpoint files are retained as explicit lineage markers.

alter table public.contentflow_build_backlog add column if not exists workflow_contract jsonb not null default '{}'::jsonb;
alter table public.contentflow_build_backlog add column if not exists workflow_state text not null default 'artifact_pending';
alter table public.contentflow_build_backlog add column if not exists patch_feedback text;
alter table public.contentflow_build_backlog add column if not exists artifact_version integer not null default 0;
alter table public.contentflow_build_backlog add column if not exists last_checkpoint_at timestamptz;

create table if not exists public.contentflow_durable_task_stages(
  backlog_task_id bigint not null references public.contentflow_build_backlog(id) on delete cascade,
  project_key text not null,
  task_key text not null,
  stage_name text not null,
  stage_state text not null default 'pending',
  attempts integer not null default 0,
  artifact_version integer not null default 0,
  last_error_class text,
  last_error text,
  checkpoint jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  primary key(backlog_task_id,stage_name)
);
create index if not exists idx_durable_task_stages_project_state on public.contentflow_durable_task_stages(project_key,stage_state,updated_at);

create or replace function public.contentflow_contract_runtime_required(p_contract jsonb,p_task_type text,p_title text,p_description text,p_acceptance_criteria text)
returns boolean language sql immutable set search_path to 'public' as $function$
  select case
    when coalesce(p_contract,'{}'::jsonb) ? 'runtime_required' then coalesce((p_contract->>'runtime_required')::boolean,false)
    when coalesce(p_contract->>'contract_version','')<>'' then false
    else public.contentflow_requires_runtime_evidence(p_task_type,p_title,p_description,p_acceptance_criteria)
  end
$function$;

create or replace function public.contentflow_checkpoint_stage(p_backlog_task_id bigint,p_stage_name text,p_stage_state text,p_error_class text default null,p_error text default null,p_checkpoint jsonb default '{}'::jsonb)
returns jsonb language plpgsql security definer set search_path to 'public' as $function$
declare b public.contentflow_build_backlog%rowtype;
begin
 if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'service_role_required'; end if;
 select * into b from public.contentflow_build_backlog where id=p_backlog_task_id;
 if not found then return jsonb_build_object('ok',false,'reason','task_not_found'); end if;
 insert into public.contentflow_durable_task_stages(backlog_task_id,project_key,task_key,stage_name,stage_state,attempts,artifact_version,last_error_class,last_error,checkpoint,updated_at)
 values(b.id,b.project_key,b.task_key,p_stage_name,p_stage_state,case when p_stage_state in ('running','rejected','failed') then 1 else 0 end,b.artifact_version,p_error_class,left(p_error,2000),coalesce(p_checkpoint,'{}'::jsonb),now())
 on conflict(backlog_task_id,stage_name) do update set stage_state=excluded.stage_state,attempts=public.contentflow_durable_task_stages.attempts+case when excluded.stage_state in ('running','rejected','failed') then 1 else 0 end,artifact_version=excluded.artifact_version,last_error_class=excluded.last_error_class,last_error=excluded.last_error,checkpoint=public.contentflow_durable_task_stages.checkpoint||excluded.checkpoint,updated_at=now();
 update public.contentflow_build_backlog set last_checkpoint_at=now() where id=b.id;
 return jsonb_build_object('ok',true,'task_key',b.task_key,'stage',p_stage_name,'state',p_stage_state);
end $function$;

create or replace function public.contentflow_guard_backlog_completion()
returns trigger language plpgsql set search_path to 'public' as $function$
declare need_runtime boolean;
begin
 need_runtime:=public.contentflow_contract_runtime_required(new.workflow_contract,new.task_type,new.title,new.description,new.acceptance_criteria);
 if new.status='completed' and need_runtime and not coalesce(new.runtime_verified,false) then
   new.status:='verification_required'; new.workflow_state:='runtime_verification_wait'; new.completion_phase:='verification_required'; new.updated_at:=now();
 elsif new.status='completed' then
   new.workflow_state:='completed'; new.completion_phase:=case when coalesce(new.runtime_verified,false) then 'runtime_proven' else 'artifact_approved' end; new.patch_feedback:=null; new.updated_at:=now();
 end if;
 return new;
end $function$;

drop trigger if exists trg_contentflow_guard_backlog_completion on public.contentflow_build_backlog;
create trigger trg_contentflow_guard_backlog_completion before insert or update of status,runtime_verified on public.contentflow_build_backlog for each row execute function public.contentflow_guard_backlog_completion();

create or replace function public.contentflow_guard_builder_completion()
returns trigger language plpgsql set search_path to 'public' as $function$
declare b public.contentflow_build_backlog%rowtype; need_runtime boolean;
begin
 if new.status='completed' then
  select * into b from public.contentflow_build_backlog where id=new.backlog_task_id;
  if found then
   need_runtime:=public.contentflow_contract_runtime_required(b.workflow_contract,b.task_type,b.title,b.description,b.acceptance_criteria);
   if need_runtime and not coalesce(b.runtime_verified,false) then new.status:='verification_required'; new.finished_at:=null; new.error:='RUNTIME_VERIFICATION_REQUIRED';
   else new.error:=null; new.finished_at:=coalesce(new.finished_at,now()); end if;
  end if;
 end if;
 return new;
end $function$;

drop trigger if exists trg_contentflow_guard_builder_completion on public.contentflow_builder_runs;
create trigger trg_contentflow_guard_builder_completion before insert or update of status on public.contentflow_builder_runs for each row execute function public.contentflow_guard_builder_completion();

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

revoke all on function public.contentflow_checkpoint_stage(bigint,text,text,text,text,jsonb) from public,anon,authenticated;
grant execute on function public.contentflow_checkpoint_stage(bigint,text,text,text,text,jsonb) to service_role;
revoke all on function public.contentflow_durable_contract_reconcile(text) from public,anon,authenticated;
grant execute on function public.contentflow_durable_contract_reconcile(text) to service_role;
