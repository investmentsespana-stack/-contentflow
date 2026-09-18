-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.


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
  v_semantic_error boolean := false;
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
       v_stdout ~* 'No se puede '
    or v_stdout ~* 'Cannot '
    or v_stdout ~* 'doesn''t exist'
    or v_stdout ~* 'Nothing to paste'
    or v_stdout ~* 'Parameter ''.+'' is missing';

  v_pass := new.state='SUCCEEDED'
            and coalesce((new.result->>'returncode')::int,-1)=0
            and new.result->>'transport'='sqcli_process'
            and new.result->>'command'=new.command_type
            and not v_semantic_error;

  if v_pass then
    v_reason := 'deterministic_runtime_evidence_pass';
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

with bad as (
  select c.id as bridge_command_id, r.id as request_id
  from public.trading_sqx_bridge_commands c
  join public.trading_sqx_director_requests r on r.bridge_command_id=c.id
  where c.state='SUCCEEDED'
    and (
         coalesce(c.result->>'stdout','') ~* 'No se puede '
      or coalesce(c.result->>'stdout','') ~* 'Cannot '
      or coalesce(c.result->>'stdout','') ~* 'doesn''t exist'
      or coalesce(c.result->>'stdout','') ~* 'Nothing to paste'
      or coalesce(c.result->>'stdout','') ~* 'Parameter ''.+'' is missing'
    )
)
update public.trading_sqx_director_requests r
set state='FAILED', blocked_reason='semantic_cli_failure_detected', updated_at=now()
from bad
where r.id=bad.request_id;

with bad as (
  select c.id as bridge_command_id, r.id as request_id, c.command_type, c.result, c.completed_at, c.state
  from public.trading_sqx_bridge_commands c
  join public.trading_sqx_director_requests r on r.bridge_command_id=c.id
  where c.state='SUCCEEDED'
    and (
         coalesce(c.result->>'stdout','') ~* 'No se puede '
      or coalesce(c.result->>'stdout','') ~* 'Cannot '
      or coalesce(c.result->>'stdout','') ~* 'doesn''t exist'
      or coalesce(c.result->>'stdout','') ~* 'Nothing to paste'
      or coalesce(c.result->>'stdout','') ~* 'Parameter ''.+'' is missing'
    )
)
insert into public.trading_sqx_rara_verifications(director_request_id,bridge_command_id,verdict,reason,evidence)
select request_id,bridge_command_id,'FAIL','semantic_cli_failure_detected',
       jsonb_build_object(
         'bridge_state',state,
         'command_type',command_type,
         'returncode',result->'returncode',
         'transport',result->'transport',
         'sqcli_path',result->'sqcli_path',
         'semantic_error',true,
         'completed_at',completed_at
       )
from bad
on conflict (bridge_command_id) do update
set verdict=excluded.verdict, reason=excluded.reason, evidence=excluded.evidence;
