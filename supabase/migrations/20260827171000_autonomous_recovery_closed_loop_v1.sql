-- CONTENTFLOW_CHANGE_PROVENANCE_V1
-- change-class: function
-- repair-recipe: opc_autonomous_recovery_closed_loop_v1
-- migration-name: autonomous_recovery_closed_loop_v1
-- intended-authority: service_role_only
-- risk: medium
-- rollback: restore previous contentflow_autonomy_supervisor definition and drop contentflow_autonomous_recovery_closed_loop_v1

create or replace function public.contentflow_autonomous_recovery_closed_loop_v1(
  p_project_key text default 'contentflow',
  p_max_dispatch integer default 10
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_before jsonb := '{}'::jsonb;
  v_reconcile_pre jsonb := '{}'::jsonb;
  v_cycle jsonb := '{}'::jsonb;
  v_reconcile_post jsonb := '{}'::jsonb;
  v_after jsonb := '{}'::jsonb;
  v_ready_before int := 0;
  v_running_before int := 0;
  v_dispatchable_before int := 0;
  v_ready_after int := 0;
  v_running_after int := 0;
  v_dispatchable_after int := 0;
  v_open_after int := 0;
  v_progress_ok boolean := false;
  v_incident_created int := 0;
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'service_role_required';
  end if;

  p_max_dispatch := greatest(0, least(coalesce(p_max_dispatch,10),10));

  select count(*) into v_ready_before from public.director_worker_queue where status='ready';
  select count(*) into v_running_before from public.director_worker_queue where status='running';
  begin
    v_dispatchable_before := public.contentflow_dispatchable_count(p_project_key);
  exception when others then
    v_dispatchable_before := 0;
  end;
  v_before := jsonb_build_object(
    'workers_ready',v_ready_before,
    'workers_running',v_running_before,
    'dispatchable',v_dispatchable_before
  );

  -- Pass 1: reconcile durable contracts, retries, stalls, incidents and known repairs.
  begin
    v_reconcile_pre := public.contentflow_master_reconcile(p_project_key);
  exception when others then
    v_reconcile_pre := jsonb_build_object('error',sqlerrm);
  end;

  -- Execute the serialized Director cycle only after the recovery plane has converged as far as it can.
  begin
    v_cycle := public.contentflow_director_core_cycle(p_project_key,p_max_dispatch);
  exception when others then
    v_cycle := jsonb_build_object('ok',false,'status','failed','error',sqlerrm);
  end;

  -- Pass 2: validate/reconcile state changed by dispatch before declaring the loop healthy.
  begin
    v_reconcile_post := public.contentflow_master_reconcile(p_project_key);
  exception when others then
    v_reconcile_post := jsonb_build_object('error',sqlerrm);
  end;

  select count(*) into v_ready_after from public.director_worker_queue where status='ready';
  select count(*) into v_running_after from public.director_worker_queue where status='running';
  begin
    v_dispatchable_after := public.contentflow_dispatchable_count(p_project_key);
  exception when others then
    v_dispatchable_after := 0;
  end;
  select count(*) into v_open_after
  from public.director_repair_incidents
  where project_key=p_project_key
    and status in ('open','analyzing','repairing','validating','needs_help');

  -- Progress is valid when work is running, work remains dispatchable, or there is no ready worker demand.
  -- This deliberately does not treat a successful function return as proof of recovery.
  v_progress_ok := (v_running_after > 0 or v_dispatchable_after > 0 or v_ready_after = 0);

  if not v_progress_ok then
    insert into public.director_repair_incidents(
      project_key,component,error_class,error_fingerprint,symptom,evidence,risk_level,status,max_attempts,requires_human
    )
    select p_project_key,'director_control','closed_loop_no_progress','closed_loop_no_progress:v1',
      'Autonomous recovery loop completed but no running or dispatchable work emerged while ready workers remain',
      jsonb_build_object(
        'before',v_before,
        'after',jsonb_build_object('workers_ready',v_ready_after,'workers_running',v_running_after,'dispatchable',v_dispatchable_after),
        'director_cycle',v_cycle,
        'open_incidents',v_open_after
      ),
      'medium','open',3,false
    where not exists(
      select 1 from public.director_repair_incidents i
      where i.project_key=p_project_key
        and i.error_fingerprint='closed_loop_no_progress:v1'
        and i.status in ('open','analyzing','repairing','validating','needs_help')
    );
    get diagnostics v_incident_created=row_count;
  else
    update public.director_repair_incidents
       set status='resolved',requires_human=false,resolved_at=now(),updated_at=now(),
           outcome='closed_loop_progress_restored_v1',validation='running_or_dispatchable_or_no_ready_worker_demand'
     where project_key=p_project_key
       and error_fingerprint='closed_loop_no_progress:v1'
       and status in ('open','analyzing','repairing','validating','needs_help');
  end if;

  v_after := jsonb_build_object(
    'workers_ready',v_ready_after,
    'workers_running',v_running_after,
    'dispatchable',v_dispatchable_after,
    'open_incidents',v_open_after,
    'progress_ok',v_progress_ok
  );

  insert into public.director_autonomy_events(
    project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at
  ) values (
    p_project_key,'autonomous_recovery_closed_loop','opc_runtime_v1','reconcile_execute_verify',
    case when v_progress_ok then 'converged_or_progressing' else 'degraded_no_progress' end,
    false,
    jsonb_build_object('before',v_before,'after',v_after,'incident_created',v_incident_created)::text,
    now()
  );

  return jsonb_build_object(
    'architecture','AUTONOMOUS_RECOVERY_CLOSED_LOOP_V1',
    'before',v_before,
    'reconcile_pre',v_reconcile_pre,
    'director_cycle',v_cycle,
    'reconcile_post',v_reconcile_post,
    'after',v_after,
    'incident_created',v_incident_created
  );
end
$function$;

revoke all on function public.contentflow_autonomous_recovery_closed_loop_v1(text,integer) from public, anon, authenticated;
grant execute on function public.contentflow_autonomous_recovery_closed_loop_v1(text,integer) to service_role;

create or replace function public.contentflow_autonomy_supervisor(
  p_project_key text default 'contentflow',
  p_max_dispatch integer default 10
) returns jsonb
language sql
security definer
set search_path to 'public'
as $function$
  select public.contentflow_autonomous_recovery_closed_loop_v1(p_project_key,p_max_dispatch);
$function$;

revoke all on function public.contentflow_autonomy_supervisor(text,integer) from public, anon, authenticated;
grant execute on function public.contentflow_autonomy_supervisor(text,integer) to service_role;
