-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create table if not exists public.trading_sqx_governance_policy (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null unique references public.trading_sqx_bridge_devices(id) on delete cascade,
  mode text not null default 'READ_ONLY' check (mode in ('READ_ONLY','RESEARCH_CONTROL')),
  allowed_projects text[] not null default '{}',
  require_local_control boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.trading_sqx_director_requests (
  id uuid primary key default gen_random_uuid(),
  device_id uuid not null references public.trading_sqx_bridge_devices(id) on delete cascade,
  command_type text not null check (command_type in ('list_projects','list_databanks','status_project','run_project','stop_project')),
  project text,
  state text not null default 'QUEUED' check (state in ('QUEUED','BLOCKED','DISPATCHED','COMPLETED','FAILED')),
  policy_snapshot jsonb not null default '{}'::jsonb,
  bridge_command_id uuid references public.trading_sqx_bridge_commands(id) on delete set null,
  blocked_reason text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table if not exists public.trading_sqx_rara_verifications (
  id uuid primary key default gen_random_uuid(),
  director_request_id uuid references public.trading_sqx_director_requests(id) on delete cascade,
  bridge_command_id uuid not null references public.trading_sqx_bridge_commands(id) on delete cascade,
  verdict text not null check (verdict in ('PASS','FAIL')),
  reason text not null,
  evidence jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  unique (bridge_command_id)
);

insert into public.trading_sqx_governance_policy(device_id, mode, allowed_projects, require_local_control)
select id, 'READ_ONLY', array['Builder']::text[], true
from public.trading_sqx_bridge_devices
where status='ACTIVE'
on conflict (device_id) do update
set mode='READ_ONLY',
    allowed_projects=excluded.allowed_projects,
    require_local_control=true,
    updated_at=now();

create or replace function public.trading_sqx_director_dispatch(p_command_type text, p_project text default null)
returns table(request_id uuid, bridge_command_id uuid, state text, reason text)
language plpgsql
security definer
set search_path = public
as $$
declare
  v_device public.trading_sqx_bridge_devices%rowtype;
  v_policy public.trading_sqx_governance_policy%rowtype;
  v_req uuid;
  v_cmd uuid;
  v_payload jsonb := '{}'::jsonb;
  v_control boolean := false;
  v_capabilities jsonb;
  v_allowed boolean := false;
  v_reason text := null;
begin
  if p_command_type not in ('list_projects','list_databanks','status_project','run_project','stop_project') then
    raise exception 'unsupported_command_type';
  end if;

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
  elsif p_command_type in ('list_databanks','status_project','run_project','stop_project') and coalesce(trim(p_project),'')='' then
    v_reason := 'project_required';
  elsif p_command_type in ('list_projects','list_databanks','status_project') then
    v_allowed := true;
  else
    v_control := coalesce((v_device.last_health->>'project_control_enabled')::boolean,false);
    if v_policy.mode <> 'RESEARCH_CONTROL' then
      v_reason := 'cloud_policy_read_only';
    elsif v_policy.require_local_control and not v_control then
      v_reason := 'local_project_control_disabled';
    elsif not (p_project = any(v_policy.allowed_projects)) then
      v_reason := 'project_not_allowlisted';
    else
      v_allowed := true;
    end if;
  end if;

  insert into public.trading_sqx_director_requests(device_id,command_type,project,state,policy_snapshot,blocked_reason)
  values (
    v_device.id,
    p_command_type,
    p_project,
    case when v_allowed then 'QUEUED' else 'BLOCKED' end,
    jsonb_build_object(
      'mode',v_policy.mode,
      'allowed_projects',v_policy.allowed_projects,
      'require_local_control',v_policy.require_local_control,
      'local_project_control_enabled',coalesce((v_device.last_health->>'project_control_enabled')::boolean,false),
      'device_last_seen_at',v_device.last_seen_at,
      'transport',v_device.last_health->>'transport',
      'sqx_cli_ok',v_device.last_health->'sqx_cli_ok'
    ),
    v_reason
  ) returning id into v_req;

  if not v_allowed then
    return query select v_req, null::uuid, 'BLOCKED'::text, v_reason;
    return;
  end if;

  if p_command_type <> 'list_projects' then
    v_payload := jsonb_build_object('project',p_project);
  end if;

  insert into public.trading_sqx_bridge_commands(device_id,command_type,payload,state)
  values (v_device.id,p_command_type,v_payload,'QUEUED')
  returning id into v_cmd;

  update public.trading_sqx_director_requests
  set state='DISPATCHED', bridge_command_id=v_cmd, updated_at=now()
  where id=v_req;

  return query select v_req, v_cmd, 'DISPATCHED'::text, null::text;
end;
$$;

create or replace function public.trading_sqx_rara_verify_command()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_req public.trading_sqx_director_requests%rowtype;
  v_pass boolean;
  v_reason text;
  v_evidence jsonb;
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

  v_pass := new.state='SUCCEEDED'
            and coalesce((new.result->>'returncode')::int,-1)=0
            and new.result->>'transport'='sqcli_process'
            and new.result->>'command'=new.command_type;

  if v_pass then
    v_reason := 'deterministic_runtime_evidence_pass';
  else
    v_reason := coalesce(new.error,'runtime_evidence_failed');
  end if;

  v_evidence := jsonb_build_object(
    'bridge_state',new.state,
    'command_type',new.command_type,
    'returncode',new.result->'returncode',
    'transport',new.result->'transport',
    'sqcli_path',new.result->'sqcli_path',
    'completed_at',new.completed_at
  );

  insert into public.trading_sqx_rara_verifications(director_request_id,bridge_command_id,verdict,reason,evidence)
  values (v_req.id,new.id,case when v_pass then 'PASS' else 'FAIL' end,v_reason,v_evidence)
  on conflict (bridge_command_id) do update
  set verdict=excluded.verdict, reason=excluded.reason, evidence=excluded.evidence;

  update public.trading_sqx_director_requests
  set state=case when v_pass then 'COMPLETED' else 'FAILED' end,
      updated_at=now()
  where id=v_req.id;

  return new;
end;
$$;

drop trigger if exists trg_trading_sqx_rara_verify on public.trading_sqx_bridge_commands;
create trigger trg_trading_sqx_rara_verify
after update of state on public.trading_sqx_bridge_commands
for each row execute function public.trading_sqx_rara_verify_command();

revoke all on function public.trading_sqx_director_dispatch(text,text) from public;
grant execute on function public.trading_sqx_director_dispatch(text,text) to service_role;

alter table public.trading_sqx_governance_policy enable row level security;
alter table public.trading_sqx_director_requests enable row level security;
alter table public.trading_sqx_rara_verifications enable row level security;
