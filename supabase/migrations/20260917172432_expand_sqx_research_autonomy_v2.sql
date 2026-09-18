-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

alter table public.trading_sqx_bridge_commands
  drop constraint if exists trading_sqx_bridge_commands_command_type_check;

alter table public.trading_sqx_bridge_commands
  add constraint trading_sqx_bridge_commands_command_type_check
  check (command_type = any (array[
    'cli_help'::text,
    'list_projects'::text,
    'list_databanks'::text,
    'status_project'::text,
    'list_symbols'::text,
    'list_instruments'::text,
    'list_timezones'::text,
    'count_databank'::text,
    'export_databank'::text,
    'list_strategies'::text,
    'get_strategy_stats'::text,
    'save_project_config'::text,
    'run_project'::text,
    'stop_project'::text,
    'pause_project'::text,
    'resume_project'::text,
    'load_project_config'::text,
    'update_data'::text,
    'create_databank'::text,
    'copy_databank'::text,
    'move_databank'::text
  ]));

alter table public.trading_sqx_director_requests
  drop constraint if exists trading_sqx_director_requests_command_type_check;

alter table public.trading_sqx_director_requests
  add constraint trading_sqx_director_requests_command_type_check
  check (command_type = any (array[
    'cli_help'::text,
    'list_projects'::text,
    'list_databanks'::text,
    'status_project'::text,
    'list_symbols'::text,
    'list_instruments'::text,
    'list_timezones'::text,
    'count_databank'::text,
    'export_databank'::text,
    'list_strategies'::text,
    'get_strategy_stats'::text,
    'save_project_config'::text,
    'run_project'::text,
    'stop_project'::text,
    'pause_project'::text,
    'resume_project'::text,
    'load_project_config'::text,
    'update_data'::text,
    'create_databank'::text,
    'copy_databank'::text,
    'move_databank'::text
  ]));

create or replace function public.trading_sqx_director_dispatch_v2(
  p_command_type text,
  p_project text default null,
  p_payload jsonb default '{}'::jsonb
)
returns table(request_id uuid, bridge_command_id uuid, state text, reason text)
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_device public.trading_sqx_bridge_devices%rowtype;
  v_policy public.trading_sqx_governance_policy%rowtype;
  v_req uuid;
  v_cmd uuid;
  v_payload jsonb := coalesce(p_payload,'{}'::jsonb);
  v_control boolean := false;
  v_capabilities jsonb;
  v_allowed boolean := false;
  v_reason text := null;
  v_project text := nullif(trim(coalesce(p_project,'')),'');
  v_dest_project text := nullif(trim(coalesce(v_payload->>'dest_project','')),'');
  v_requires_project boolean;
  v_read_only boolean;
begin
  if p_command_type not in (
    'cli_help','list_projects','list_databanks','status_project','list_symbols','list_instruments','list_timezones',
    'count_databank','export_databank','list_strategies','get_strategy_stats','save_project_config',
    'run_project','stop_project','pause_project','resume_project','load_project_config','update_data',
    'create_databank','copy_databank','move_databank'
  ) then
    raise exception 'unsupported_command_type';
  end if;

  v_requires_project := p_command_type in (
    'list_databanks','status_project','count_databank','export_databank','list_strategies','get_strategy_stats',
    'save_project_config','run_project','stop_project','pause_project','resume_project','load_project_config',
    'create_databank','copy_databank','move_databank'
  );

  v_read_only := p_command_type in (
    'cli_help','list_projects','list_databanks','status_project','list_symbols','list_instruments','list_timezones',
    'count_databank','export_databank','list_strategies','get_strategy_stats','save_project_config'
  );

  select * into v_device
  from public.trading_sqx_bridge_devices
  where status='ACTIVE'
  order by last_seen_at desc nulls last
  limit 1;

  if v_device.id is null then
    raise exception 'no_active_sqx_device';
  end if;

  select * into v_policy
  from public.trading_sqx_governance_policy
  where device_id=v_device.id;

  if v_policy.id is null then
    raise exception 'missing_governance_policy';
  end if;

  v_capabilities := coalesce(v_device.last_health->'capabilities','[]'::jsonb);

  if not (v_capabilities ? p_command_type) then
    v_reason := 'device_capability_missing';
  elsif v_requires_project and v_project is null then
    v_reason := 'project_required';
  elsif v_read_only then
    v_allowed := true;
  else
    v_control := coalesce((v_device.last_health->>'project_control_enabled')::boolean,false);
    if v_policy.mode <> 'RESEARCH_CONTROL' then
      v_reason := 'cloud_policy_read_only';
    elsif v_policy.require_local_control and not v_control then
      v_reason := 'local_project_control_disabled';
    elsif v_project is not null and not (v_project = any(v_policy.allowed_projects)) then
      v_reason := 'project_not_allowlisted';
    elsif v_dest_project is not null and not (v_dest_project = any(v_policy.allowed_projects)) then
      v_reason := 'destination_project_not_allowlisted';
    else
      v_allowed := true;
    end if;
  end if;

  if v_project is not null then
    v_payload := v_payload || jsonb_build_object('project',v_project);
  end if;

  insert into public.trading_sqx_director_requests(device_id,command_type,project,state,policy_snapshot,blocked_reason)
  values (
    v_device.id,
    p_command_type,
    v_project,
    case when v_allowed then 'QUEUED' else 'BLOCKED' end,
    jsonb_build_object(
      'mode',v_policy.mode,
      'allowed_projects',v_policy.allowed_projects,
      'require_local_control',v_policy.require_local_control,
      'local_project_control_enabled',coalesce((v_device.last_health->>'project_control_enabled')::boolean,false),
      'device_last_seen_at',v_device.last_seen_at,
      'transport',v_device.last_health->>'transport',
      'sqx_cli_ok',v_device.last_health->'sqx_cli_ok',
      'payload_keys',(select coalesce(jsonb_agg(k),'[]'::jsonb) from jsonb_object_keys(v_payload) as k)
    ),
    v_reason
  ) returning id into v_req;

  if not v_allowed then
    return query select v_req, null::uuid, 'BLOCKED'::text, v_reason;
    return;
  end if;

  insert into public.trading_sqx_bridge_commands(device_id,command_type,payload,state)
  values (v_device.id,p_command_type,v_payload,'QUEUED')
  returning id into v_cmd;

  update public.trading_sqx_director_requests
  set state='DISPATCHED', bridge_command_id=v_cmd, updated_at=now()
  where id=v_req;

  return query select v_req, v_cmd, 'DISPATCHED'::text, null::text;
end;
$function$;

create or replace function public.trading_sqx_director_dispatch(
  p_command_type text,
  p_project text default null
)
returns table(request_id uuid, bridge_command_id uuid, state text, reason text)
language sql
security definer
set search_path to 'public'
as $function$
  select * from public.trading_sqx_director_dispatch_v2(p_command_type,p_project,'{}'::jsonb);
$function$;
