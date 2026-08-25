create or replace function public.contentflow_deferred_progress_watchdog_v1(p_project_key text default 'contentflow')
returns jsonb
language plpgsql
security definer
set search_path='public'
as $$
declare
  v_total int:=0;
  v_obsolete int:=0;
  v_due int:=0;
  v_missing_wakeup int:=0;
  v_reactivated int:=0;
  v_incident_created int:=0;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then
    raise exception 'service_role_required';
  end if;

  select count(*) into v_total
  from public.contentflow_build_backlog
  where project_key=p_project_key and status='deferred';

  select count(*) into v_obsolete
  from public.contentflow_build_backlog
  where project_key=p_project_key and status='deferred'
    and coalesce(blocked_reason,'') like 'OBSOLETE%';

  select count(*) into v_due
  from public.contentflow_build_backlog
  where project_key=p_project_key and status='deferred'
    and next_eligible_at is not null and next_eligible_at<=now()
    and coalesce(blocked_reason,'') not like 'OBSOLETE%';

  update public.contentflow_build_backlog
     set status='ready', blocked_reason=null, updated_at=now()
   where project_key=p_project_key and status='deferred'
     and next_eligible_at is not null and next_eligible_at<=now()
     and coalesce(blocked_reason,'') not like 'OBSOLETE%';
  get diagnostics v_reactivated=row_count;

  select count(*) into v_missing_wakeup
  from public.contentflow_build_backlog
  where project_key=p_project_key and status='deferred'
    and next_eligible_at is null
    and coalesce(blocked_reason,'') not like 'OBSOLETE%';

  if v_missing_wakeup>0 and not exists (
    select 1 from public.director_repair_incidents
    where project_key=p_project_key
      and error_fingerprint='deferred_missing_wakeup:v1'
      and status in ('open','analyzing','repairing','validating','needs_help')
  ) then
    insert into public.director_repair_incidents(
      project_key,component,error_class,error_fingerprint,symptom,evidence,
      risk_level,status,max_attempts,requires_human,root_cause,proposed_action
    ) values (
      p_project_key,'director_control','deferred_progress_stall','deferred_missing_wakeup:v1',
      'Deferred tasks exist without an explicit wake-up condition',
      jsonb_build_object('deferred_total',v_total,'obsolete',v_obsolete,'missing_wakeup',v_missing_wakeup,'due_reactivated',v_reactivated),
      'medium','open',3,false,
      'Deferred state lacks next_eligible_at or an explicit terminal/obsolete reason',
      'Classify each deferred task and assign an explicit wake-up condition, dependency, or obsolete terminal reason'
    );
    get diagnostics v_incident_created=row_count;
  end if;

  insert into public.director_autonomy_events(
    project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at
  ) values (
    p_project_key,'deferred_progress_watchdog','master_director_v3','durable_wait_contract',
    case when v_missing_wakeup=0 then 'healthy' else 'repair_required' end,
    false,
    jsonb_build_object('deferred_total',v_total,'obsolete',v_obsolete,'due',v_due,'reactivated',v_reactivated,'missing_wakeup',v_missing_wakeup,'incident_created',v_incident_created)::text,
    now()
  );

  return jsonb_build_object(
    'architecture','DEFERRED_PROGRESS_WATCHDOG_V1',
    'deferred_total',v_total,
    'obsolete',v_obsolete,
    'due',v_due,
    'reactivated',v_reactivated,
    'missing_wakeup',v_missing_wakeup,
    'incident_created',v_incident_created
  );
end $$;

revoke all on function public.contentflow_deferred_progress_watchdog_v1(text) from public,anon,authenticated;
grant execute on function public.contentflow_deferred_progress_watchdog_v1(text) to service_role;
