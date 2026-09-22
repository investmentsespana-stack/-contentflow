-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.


create or replace function public.trading_sqx_director_dispatch_payload(
  p_command_type text,
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
  v_control boolean := false;
  v_capabilities jsonb;
  v_allowed boolean := false;
  v_reason text := null;
  v_project text := nullif(trim(coalesce(p_payload->>'project', p_payload->>'name','')), '');
  v_read_only constant text[] := array[
    'cli_help','list_projects','list_databanks','status_project','list_symbols','list_instruments',
    'list_timezones','count_databank','export_databank','list_strategies','get_strategy_stats',
    'save_project_config'
  ];
  v_control_cmds constant text[] := array[
    'run_project','stop_project','pause_project','resume_project','load_project_config','update_data',
    'create_databank','copy_databank','move_databank','freeze_databank','run_vibe_asset_research'
  ];
  v_project_required constant text[] := array[
    'list_databanks','status_project','count_databank','export_databank','list_strategies',
    'get_strategy_stats','save_project_config','run_project','stop_project','pause_project',
    'resume_project','load_project_config','create_databank','copy_databank','move_databank',
    'freeze_databank'
  ];
  v_vibe_action text := lower(trim(coalesce(p_payload->>'action','')));
  v_vibe_asset text := upper(trim(coalesce(p_payload->>'asset','')));
  v_vibe_run_id text := trim(coalesce(p_payload->>'run_id',''));
begin
  if not (p_command_type = any(v_read_only) or p_command_type = any(v_control_cmds)) then
    raise exception 'unsupported_command_type';
  end if;

  select * into v_device
  from public.trading_sqx_bridge_devices
  where status='ACTIVE'
  order by last_seen_at desc nulls last
  limit 1;
  if v_device.id is null then raise exception 'no_active_sqx_device'; end if;

  select * into v_policy
  from public.trading_sqx_governance_policy
  where device_id=v_device.id;
  if v_policy.id is null then raise exception 'missing_governance_policy'; end if;

  v_capabilities := coalesce(v_device.last_health->'capabilities','[]'::jsonb);

  if not (v_capabilities ? p_command_type) then
    v_reason := 'device_capability_missing';
  elsif p_command_type = any(v_project_required) and v_project is null then
    v_reason := 'project_required';
  elsif p_command_type='freeze_databank' and nullif(trim(coalesce(p_payload->>'databank','')), '') is null then
    v_reason := 'databank_required';
  elsif p_command_type='run_vibe_asset_research' and not (
    v_vibe_action in ('start','status','result')
    and (
      (v_vibe_action='start' and v_vibe_asset in ('NQ','ES','CL','GC','DXY'))
      or
      (v_vibe_action in ('status','result') and v_vibe_run_id <> '')
    )
  ) then
    v_reason := 'vibe_payload_not_approved';
  elsif p_command_type = any(v_read_only) then
    v_allowed := true;
  else
    v_control := coalesce((v_device.last_health->>'project_control_enabled')::boolean,false);
    if v_policy.mode <> 'RESEARCH_CONTROL' then
      v_reason := 'cloud_policy_read_only';
    elsif v_policy.require_local_control and not v_control then
      v_reason := 'local_project_control_disabled';
    elsif v_project is not null and not (v_project = any(v_policy.allowed_projects)) then
      v_reason := 'project_not_allowlisted';
    else
      v_allowed := true;
    end if;
  end if;

  insert into public.trading_sqx_director_requests(
    device_id,command_type,project,state,policy_snapshot,blocked_reason
  )
  values (
    v_device.id,p_command_type,v_project,
    case when v_allowed then 'QUEUED' else 'BLOCKED' end,
    jsonb_build_object(
      'mode',v_policy.mode,
      'allowed_projects',v_policy.allowed_projects,
      'require_local_control',v_policy.require_local_control,
      'local_project_control_enabled',coalesce((v_device.last_health->>'project_control_enabled')::boolean,false),
      'device_last_seen_at',v_device.last_seen_at,
      'transport',v_device.last_health->>'transport',
      'sqx_cli_ok',v_device.last_health->'sqx_cli_ok',
      'payload_keys',(select coalesce(jsonb_agg(key),'[]'::jsonb) from jsonb_object_keys(coalesce(p_payload,'{}'::jsonb)) key)
    ),
    v_reason
  ) returning id into v_req;

  if not v_allowed then
    return query select v_req, null::uuid, 'BLOCKED'::text, v_reason;
    return;
  end if;

  insert into public.trading_sqx_bridge_commands(device_id,command_type,payload,state)
  values (v_device.id,p_command_type,coalesce(p_payload,'{}'::jsonb),'QUEUED')
  returning id into v_cmd;

  update public.trading_sqx_director_requests
  set state='DISPATCHED', bridge_command_id=v_cmd, updated_at=now()
  where id=v_req;

  return query select v_req, v_cmd, 'DISPATCHED'::text, null::text;
end;
$function$;
