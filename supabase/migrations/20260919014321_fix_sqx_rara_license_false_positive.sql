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
