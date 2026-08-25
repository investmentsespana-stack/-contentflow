-- Reconstructed from the live production catalog on 2026-08-25.
-- Idempotent current-state bridge for backlog control triggers omitted from Recovery.

create or replace function public.audit_builder_claim()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_token text:=gen_random_uuid()::text;
begin
  if old.status is distinct from new.status and new.status='running' and coalesce(new.execution_lane,'llm_artifact')='llm_artifact' then
    insert into public.contentflow_builder_runs(project_key,backlog_task_id,task_key,task_type,status,selected_model,lease_token,lease_generation,heartbeat_at,lease_expires_at,control_protocol)
    values(new.project_key,new.id,new.task_key,new.task_type,'claimed',new.selected_model,v_token,1,now(),now()+interval '3 minutes','fenced-v2');
  end if;
  return new;
end $function$;

create or replace function public.contentflow_backlog_state_guard()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare durable boolean:=false;
begin
 durable:=coalesce(new.workflow_contract->>'contract_version','')<>'';
 if new.status='ready' then
   if exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=new.id and r.status='review_required') then new.status:='blocked'; new.blocked_reason:='REVIEW_PENDING'; new.next_eligible_at:=null;
   else new.blocked_reason:=null; new.next_eligible_at:=coalesce(new.next_eligible_at,now()); if not durable then update public.contentflow_retry_state set circuit_state='closed',circuit_open_until=null,next_retry_at=null,updated_at=now() where project_key=new.project_key and task_key=new.task_key and circuit_state='open'; end if; end if;
 elsif new.status='blocked' then
   if coalesce(new.blocked_reason,'')='REVIEW_PENDING' or exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=new.id and r.status='review_required') then new.blocked_reason:='REVIEW_PENDING'; new.next_eligible_at:=null;
   elsif durable and new.workflow_state in ('patch_required','artifact_patch_required','retry_wait') then new.status:='ready'; new.blocked_reason:=null; new.next_eligible_at:=coalesce(new.next_eligible_at,now()+interval '15 seconds');
   else new.blocked_reason:=coalesce(nullif(new.blocked_reason,''),'STATE_GUARD_BLOCKED_UNSPECIFIED'); new.next_eligible_at:=coalesce(new.next_eligible_at,now()+interval '7 minutes'); end if;
 end if;
 return new;
end $function$;

create or replace function public.contentflow_enforce_dynamic_running_cap()
returns trigger language plpgsql set search_path to 'public' as $function$
declare v_cap int:=1; v_prod int:=1;
begin
 if new.project_key='contentflow' and new.status='running' and old.status is distinct from 'running' and coalesce(new.execution_lane,'llm_artifact')='llm_artifact' then
  perform pg_advisory_xact_lock(hashtext('contentflow:master-running-cap'));
  begin v_cap:=public.contentflow_recommended_parallelism('contentflow'); exception when others then v_cap:=1; end;
  begin select greatest(1,coalesce(production_max,1)) into v_prod from public.contentflow_nexo_lane_status limit 1; exception when others then v_prod:=1; end;
  v_cap:=greatest(1,least(coalesce(v_cap,1),coalesce(v_prod,1)));
  if (select count(*) from public.contentflow_build_backlog b where b.project_key='contentflow' and b.status='running' and b.id<>new.id and coalesce(b.execution_lane,'llm_artifact')='llm_artifact') >= v_cap then raise exception 'contentflow_dynamic_running_cap_%',v_cap; end if;
 end if;
 return new;
end $function$;

create or replace function public.contentflow_enforce_learned_evidence_lane()
returns trigger language plpgsql as $function$
begin
 if new.project_key='contentflow' and new.epic='evidence_first' and new.task_key like 'evidence_%' and coalesce(new.description,'') like 'Produce REAL, persisted, correlated evidence%' and new.status <> 'completed' then new.execution_lane := 'evidence_producer'; end if;
 return new;
end $function$;

create or replace function public.contentflow_sync_help_and_dependents()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
begin
 if new.project_key='contentflow' and new.status='completed' and old.status is distinct from new.status then
  update public.director_help_alerts set status='resolved',resolved_at=now(),updated_at=now(),summary=coalesce(summary,'') || case when coalesce(summary,'')='' then '' else ' | ' end || 'AUTO_RESOLVED_FROM_BACKLOG_COMPLETION' where project_key='contentflow' and task_key=new.task_key and status='open';
  update public.contentflow_build_backlog p set status='ready',updated_at=now(),selected_model=null where p.project_key='contentflow' and p.status='blocked' and jsonb_array_length(coalesce(p.depends_on,'[]'::jsonb))>0 and not exists(select 1 from jsonb_array_elements_text(coalesce(p.depends_on,'[]'::jsonb)) d(dep) left join public.contentflow_build_backlog q on q.project_key='contentflow' and q.task_key=d.dep where coalesce(q.status,'missing')<>'completed');
 end if;
 return new;
end $function$;

create or replace function public.log_contentflow_autonomy_backlog()
returns trigger language plpgsql security definer set search_path to 'public' as $function$
declare v_mode text; v_started timestamptz; v_problem_id bigint;
begin
 v_mode:=case when coalesce(new.team,'') ~* '^(ranked|auto|director-core|adaptive):|^ranked-v' then 'auto' else 'manual' end;
 if new.status='running' and old.status is distinct from 'running' then insert into director_autonomy_events(project_key,event_type,task_key,source,assignment_mode,assigned_model,outcome,started_at,required_user_intervention,notes) values(new.project_key,'task_assigned',new.task_key,'contentflow_build_backlog',v_mode,new.selected_model,'assigned',now(),false,new.team); end if;
 if new.status='completed' and old.status is distinct from 'completed' then
  select started_at into v_started from director_autonomy_events where project_key=new.project_key and task_key=new.task_key and event_type='task_assigned' order by id desc limit 1;
  insert into director_autonomy_events(project_key,event_type,task_key,source,assignment_mode,assigned_model,outcome,quality_score,started_at,finished_at,resolution_seconds,required_user_intervention,notes) values(new.project_key,'task_completed',new.task_key,'contentflow_build_backlog',v_mode,new.selected_model,'completed',new.quality_score,v_started,now(),case when v_started is null then null else extract(epoch from(now()-v_started)) end,false,new.team);
  select id into v_problem_id from director_autonomy_events where project_key=new.project_key and task_key=new.task_key and event_type='problem_detected' and outcome='open' order by id desc limit 1;
  if v_problem_id is not null then select started_at into v_started from director_autonomy_events where id=v_problem_id; insert into director_autonomy_events(project_key,event_type,task_key,source,assignment_mode,assigned_model,outcome,quality_score,started_at,finished_at,resolution_seconds,required_user_intervention,notes) values(new.project_key,'problem_resolved',new.task_key,'backlog_completion',v_mode,new.selected_model,'resolved',new.quality_score,v_started,now(),case when v_started is null then null else extract(epoch from(now()-v_started)) end,false,'Resolved by subsequent successful task completion'); update director_autonomy_events set outcome='closed' where id=v_problem_id; end if;
 end if;
 return new;
end $function$;

do $$ begin
  execute 'drop trigger if exists trg_audit_builder_claim on public.contentflow_build_backlog';
  execute 'create trigger trg_audit_builder_claim after update of status on public.contentflow_build_backlog for each row execute function public.audit_builder_claim()';
  execute 'drop trigger if exists trg_contentflow_autonomy_backlog on public.contentflow_build_backlog';
  execute 'create trigger trg_contentflow_autonomy_backlog after update on public.contentflow_build_backlog for each row execute function public.log_contentflow_autonomy_backlog()';
  execute 'drop trigger if exists trg_contentflow_backlog_state_guard on public.contentflow_build_backlog';
  execute 'create trigger trg_contentflow_backlog_state_guard before insert or update of status,blocked_reason,next_eligible_at on public.contentflow_build_backlog for each row execute function public.contentflow_backlog_state_guard()';
  execute 'drop trigger if exists trg_contentflow_backlog_transition_ledger on public.contentflow_build_backlog';
  execute 'create trigger trg_contentflow_backlog_transition_ledger after update of status on public.contentflow_build_backlog for each row execute function public.contentflow_log_backlog_transition()';
  execute 'drop trigger if exists trg_contentflow_dynamic_running_cap on public.contentflow_build_backlog';
  execute 'create trigger trg_contentflow_dynamic_running_cap before update of status on public.contentflow_build_backlog for each row execute function public.contentflow_enforce_dynamic_running_cap()';
  execute 'drop trigger if exists trg_contentflow_enforce_learned_evidence_lane on public.contentflow_build_backlog';
  execute 'create trigger trg_contentflow_enforce_learned_evidence_lane before insert or update of execution_lane,epic,description,status on public.contentflow_build_backlog for each row execute function public.contentflow_enforce_learned_evidence_lane()';
  execute 'drop trigger if exists trg_contentflow_guard_dependency_graph on public.contentflow_build_backlog';
  execute 'create trigger trg_contentflow_guard_dependency_graph before insert or update of task_key,depends_on on public.contentflow_build_backlog for each row execute function public.contentflow_guard_dependency_graph()';
  execute 'drop trigger if exists trg_contentflow_set_execution_lane on public.contentflow_build_backlog';
  execute 'create trigger trg_contentflow_set_execution_lane before insert or update of task_type,description,acceptance_criteria on public.contentflow_build_backlog for each row execute function public.contentflow_set_execution_lane()';
  execute 'drop trigger if exists trg_contentflow_sync_help_and_dependents on public.contentflow_build_backlog';
  execute 'create trigger trg_contentflow_sync_help_and_dependents after update of status on public.contentflow_build_backlog for each row execute function public.contentflow_sync_help_and_dependents()';
end $$;
