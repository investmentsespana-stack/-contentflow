create or replace function public.contentflow_learned_identity_preflight(p_result text)
returns jsonb
language plpgsql
immutable
set search_path to 'public'
as $function$
declare m text[];
begin
  select array_agg(x) into m
  from (
    select distinct z[1] x
    from regexp_matches(
      coalesce(p_result,''),
      '(?i)(?:builder\s*run\s*id|builder_run_id|source_run_id|correlation\s*id|correlation_id|evidence\s*id|evidence_id)\s*(?:\||:|=)\s*([0-9]{2,}|[0-9a-f]{8}-[0-9a-f-]{27,}|[A-Za-z]+-(?:run|correlation)-[A-Za-z0-9-]+)',
      'g'
    ) z
  ) q;
  return jsonb_build_object(
    'ok',coalesce(cardinality(m),0)=0,
    'fingerprint','rara_reject_hardcoded_execution_identity_v1',
    'matches',coalesce(to_jsonb(m),'[]'::jsonb)
  );
end
$function$;

create or replace function public.contentflow_enforce_learned_preflight(p_run_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  r public.contentflow_builder_runs%rowtype;
  b public.contentflow_build_backlog%rowtype;
  chk jsonb;
  cleaned text;
  target text;
begin
  select * into r from public.contentflow_builder_runs where id=p_run_id for update;
  if not found then
    return jsonb_build_object('ok',false,'reason','run_missing');
  end if;

  select * into b from public.contentflow_build_backlog where id=r.backlog_task_id for update;
  chk:=public.contentflow_learned_identity_preflight(r.result);
  if coalesce((chk->>'ok')::boolean,false) then
    return jsonb_build_object('ok',true,'action','pass');
  end if;

  cleaned:=regexp_replace(
    coalesce(r.result,''),
    '(?im)^\s*\|?\s*(Builder\s*Run\s*ID|builder_run_id|source_run_id|correlation\s*id|correlation_id|evidence\s*id|evidence_id)\s*\|?\s*[:=|]\s*[^\n|]+\|?\s*$',
    '',
    'g'
  );
  chk:=public.contentflow_learned_identity_preflight(cleaned);

  if coalesce((chk->>'ok')::boolean,false) then
    update public.contentflow_builder_runs set result=cleaned where id=p_run_id;
    update public.contentflow_build_backlog set result=cleaned,updated_at=now() where id=b.id;
    insert into public.contentflow_runtime_event_ledger(
      project_key,builder_run_id,task_key,event_type,idempotency_key,actor,payload,trace_id
    ) values(
      b.project_key,r.id,b.task_key,'learned_preflight_repaired',
      coalesce(r.idempotency_key,'run:'||r.id)||':learned_preflight_repaired',
      'rara_learning_enforcer',
      jsonb_build_object(
        'fingerprint','rara_reject_hardcoded_execution_identity_v1',
        'repair','removed_execution_identity_metadata'
      ),
      r.trace_id
    ) on conflict do nothing;
    return jsonb_build_object(
      'ok',true,
      'action','repaired',
      'fingerprint','rara_reject_hardcoded_execution_identity_v1'
    );
  end if;

  target:=case
    when not exists(
      select 1
      from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(v)
      where not exists(
        select 1
        from public.contentflow_build_backlog x
        where x.project_key=b.project_key
          and x.task_key=d.v
          and x.status='completed'
      )
    ) then 'ready'
    else 'planned'
  end;

  update public.contentflow_builder_runs
     set status='failed',finished_at=now(),error='LEARNED_PREFLIGHT_BLOCK:rara_reject_hardcoded_execution_identity_v1'
   where id=r.id;

  update public.contentflow_build_backlog
     set status=target,selected_model=null,next_eligible_at=now(),updated_at=now()
   where id=b.id;

  return jsonb_build_object(
    'ok',false,
    'action','requeue_before_judge',
    'target_status',target,
    'fingerprint','rara_reject_hardcoded_execution_identity_v1'
  );
end
$function$;
