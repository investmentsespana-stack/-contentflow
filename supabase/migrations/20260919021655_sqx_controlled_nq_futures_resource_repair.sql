-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.


create or replace function public.trading_sqx_director_dispatch_v2(
  p_command_type text,
  p_project text default null::text,
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
  v_instrument text := nullif(trim(coalesce(v_payload->>'instrument','')),'');
  v_symbol text := nullif(trim(coalesce(v_payload->>'symbol','')),'');
begin
  if p_command_type not in (
    'cli_help','list_projects','list_databanks','status_project','list_symbols','list_instruments','list_timezones',
    'count_databank','export_databank','list_strategies','get_strategy_stats','save_project_config',
    'run_project','stop_project','pause_project','resume_project','load_project_config','update_data',
    'add_instrument','add_symbol',
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

  select p.* into v_policy
  from public.trading_sqx_governance_policy p
  join public.trading_sqx_bridge_devices d on d.id=p.device_id
  where d.status='ACTIVE'
  order by d.last_seen_at desc nulls last
  limit 1;

  if v_policy.id is null then
    raise exception 'no_active_governed_sqx_device';
  end if;

  select * into v_device
  from public.trading_sqx_bridge_devices
  where id=v_policy.device_id and status='ACTIVE';

  if v_device.id is null then
    raise exception 'governed_sqx_device_not_active';
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
    elsif p_command_type='add_instrument' and not (
      lower(coalesce(v_payload->>'datatype',''))='futures'
      and coalesce((v_payload->>'defaultspread')::numeric,-1)=2
      and (
        (v_instrument='NQ - CME' and coalesce((v_payload->>'pointvalue')::numeric,-1)=20 and coalesce((v_payload->>'ticksize')::numeric,-1)=0.25 and coalesce((v_payload->>'tickstep')::numeric,-1)=0.25)
        or
        (v_instrument='ES - CME' and coalesce((v_payload->>'pointvalue')::numeric,-1)=50 and coalesce((v_payload->>'ticksize')::numeric,-1)=0.25 and coalesce((v_payload->>'tickstep')::numeric,-1)=0.25)
        or
        (v_instrument='YM - CBOT' and coalesce((v_payload->>'pointvalue')::numeric,-1)=5 and coalesce((v_payload->>'ticksize')::numeric,-1)=1 and coalesce((v_payload->>'tickstep')::numeric,-1)=1)
      )
    ) then
      v_reason := 'resource_not_approved';
    elsif p_command_type='add_symbol' and not (
      lower(coalesce(v_payload->>'datasource',''))='file'
      and upper(coalesce(v_payload->>'datatype',''))='M1'
      and lower(coalesce(v_payload->>'bartype',''))='endofbar'
      and (
        (v_symbol='@NQ' and v_instrument='NQ - CME')
        or (v_symbol='@ES' and v_instrument='ES - CME')
        or (v_symbol='@YM' and v_instrument='YM - CBOT')
      )
    ) then
      v_reason := 'resource_not_approved';
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
      'governed_device_id',v_policy.device_id,
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

create or replace function public.trading_sqx_rara_verify_command()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_req public.trading_sqx_director_requests%rowtype;
  v_pass boolean;
  v_reason text;
  v_evidence jsonb;
  v_stdout text := coalesce(new.result->>'stdout','');
  v_error_text text := coalesce(new.error,'');
  v_semantic_error boolean := false;
  v_startup_verified boolean := coalesce((new.result->>'startup_verified')::boolean,false);
  v_text text := coalesce(new.result->>'stdout','') || E'\n' || coalesce(new.error,'');
begin
  if new.state not in ('SUCCEEDED','FAILED') or old.state = new.state then
    return new;
  end if;

  select * into v_req
  from public.trading_sqx_director_requests
  where bridge_command_id=new.id
  limit 1;

  if v_req.id is null then
    return new;
  end if;

  v_semantic_error :=
       v_text ~* 'No se puede iniciar|Cannot start project'
    or v_text ~* 'unresolved resources'
    or v_text ~* 'Cannot add instrument|Cannot add symbol|Cannot edit instrument|Cannot edit symbol'
    or v_text ~* 'check[[:space:]]+license[^\r\n]{0,80}(fail|failed)'
    or v_text ~* 'license[^\r\n]{0,80}(verification|validation)[^\r\n]{0,40}(fail|failed)'
    or v_text ~* 'doesn''t exist'
    or v_text ~* 'Nothing to paste'
    or v_text ~* 'Parameter ''.+'' is missing';

  v_pass := new.state='SUCCEEDED'
            and coalesce((new.result->>'returncode')::int,-1)=0
            and new.result->>'transport'='sqcli_process'
            and new.result->>'command'=new.command_type
            and not v_semantic_error
            and (new.command_type <> 'run_project' or v_startup_verified);

  if v_pass then
    v_reason := 'deterministic_runtime_evidence_pass';
  elsif new.command_type='run_project' and not v_startup_verified then
    v_reason := 'startup_not_certified';
  elsif v_semantic_error then
    v_reason := 'semantic_cli_failure_detected';
  else
    v_reason := coalesce(new.error,'runtime_evidence_failed');
  end if;

  v_evidence := jsonb_build_object(
    'bridge_state',new.state,
    'command_type',new.command_type,
    'returncode',new.result->'returncode',
    'transport',new.result->'transport',
    'sqcli_path',new.result->'sqcli_path',
    'semantic_error',v_semantic_error,
    'startup_verified',case when new.command_type='run_project' then v_startup_verified else null end,
    'completed_at',new.completed_at
  );

  insert into public.trading_sqx_rara_verifications(director_request_id,bridge_command_id,verdict,reason,evidence)
  values (v_req.id,new.id,case when v_pass then 'PASS' else 'FAIL' end,v_reason,v_evidence)
  on conflict (bridge_command_id) do update
  set verdict=excluded.verdict, reason=excluded.reason, evidence=excluded.evidence;

  update public.trading_sqx_director_requests
  set state=case when v_pass then 'COMPLETED' else 'FAILED' end,
      blocked_reason=case when v_pass then null else v_reason end,
      updated_at=now()
  where id=v_req.id;

  return new;
end;
$function$;
