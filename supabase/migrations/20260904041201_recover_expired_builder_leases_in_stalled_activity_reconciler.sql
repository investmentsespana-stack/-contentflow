-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_recover_stalled_activities(p_project_key text default 'contentflow'::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_now timestamptz:=now(); v_count int:=0; v_workers int:=0; v_slots int:=0; v_revoked int:=0;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 if not pg_try_advisory_xact_lock(hashtext('contentflow:activity-recovery:'||p_project_key)) then
   return jsonb_build_object('recovered_runs',0,'skipped','recovery_lock_busy','ownership_model','durable_execution_v4');
 end if;
 with stalled as (
   select r.id,r.backlog_task_id,r.task_key,r.selected_model,r.idempotency_key,r.activity_phase,
          case when r.activity_deadline_at is not null and r.activity_deadline_at<=v_now then 'activity_timeout'
               when r.activity_deadline_at is null and r.heartbeat_deadline_at is not null and r.heartbeat_deadline_at<=v_now then 'heartbeat_timeout'
               when r.lease_expires_at is not null and r.lease_expires_at<=v_now then 'lease_expired'
               when b.status is distinct from 'running' then 'backlog_state_diverged'
               else null end as cause
   from public.contentflow_builder_runs r
   left join public.contentflow_build_backlog b on b.id=r.backlog_task_id
   where r.project_key=p_project_key and r.status in ('claimed','running') and r.finished_at is null and r.lease_revoked_at is null
     and (
       (r.activity_deadline_at is not null and r.activity_deadline_at<=v_now)
       or (r.activity_deadline_at is null and r.heartbeat_deadline_at is not null and r.heartbeat_deadline_at<=v_now)
       or (r.lease_expires_at is not null and r.lease_expires_at<=v_now)
       or b.status is distinct from 'running'
     )
   order by r.id
   for update of r skip locked
 ), revoked as (
   update public.contentflow_builder_runs r
      set status='deferred',finished_at=v_now,
          error=upper(s.cause)||':'||coalesce(s.activity_phase,'unknown'),
          lease_revoked_at=v_now,lease_generation=lease_generation+1
   from stalled s where r.id=s.id returning s.*
 ), backlog as (
   update public.contentflow_build_backlog b
      set status='ready',selected_model=null,next_eligible_at=v_now,updated_at=v_now
   from revoked s
   where b.id=s.backlog_task_id and b.status='running'
   returning s.*
 ) select count(*) into v_count from backlog;
 get diagnostics v_revoked=row_count;
 update public.director_worker_queue q set status='ready',current_task_key=null,last_outcome='durable_activity_recovered_v4',updated_at=v_now
 where q.status='running' and not exists(
   select 1 from public.contentflow_builder_runs r
   where r.project_key=p_project_key and r.status in ('claimed','running') and r.finished_at is null
     and r.selected_model=q.model_id and r.task_key=q.current_task_key
 );
 get diagnostics v_workers=row_count;
 update public.contentflow_nexo_slots s set released_at=coalesce(s.released_at,v_now),release_reason=coalesce(s.release_reason,'durable_activity_recovered_v4')
 where s.released_at is null and exists(
   select 1 from public.contentflow_builder_runs r
   where r.task_key=s.task_key and r.finished_at=v_now
     and (r.error like 'ACTIVITY_TIMEOUT:%' or r.error like 'HEARTBEAT_TIMEOUT:%' or r.error like 'LEASE_EXPIRED:%' or r.error like 'BACKLOG_STATE_DIVERGED:%')
 );
 get diagnostics v_slots=row_count;
 return jsonb_build_object('recovered_runs',v_count,'runs_revoked',v_revoked,'workers_released',v_workers,'slots_released',v_slots,'ownership_model','durable_execution_v4');
end
$function$;
