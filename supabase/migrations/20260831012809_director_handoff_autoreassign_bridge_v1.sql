-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_ingest_handoff_v1(
  p_project_key text,
  p_handoff_id text,
  p_source text,
  p_actions jsonb,
  p_metadata jsonb default '{}'::jsonb
) returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_signal jsonb;
  v_action text;
  v_idx int := 0;
  v_created int := 0;
  v_stage int := 1;
  v_task_key text;
  v_source text := coalesce(nullif(trim(p_source),''),'external_handoff');
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then
    raise exception 'privileged_channel_required';
  end if;
  if coalesce(trim(p_project_key),'') = '' or coalesce(trim(p_handoff_id),'') = '' then
    raise exception 'handoff_identity_required';
  end if;
  if jsonb_typeof(coalesce(p_actions,'[]'::jsonb)) <> 'array' then
    raise exception 'handoff_actions_must_be_array';
  end if;
  if jsonb_array_length(coalesce(p_actions,'[]'::jsonb)) > 20 then
    raise exception 'handoff_actions_limit_exceeded';
  end if;

  v_signal := public.contentflow_record_durable_signal_v1(
    p_project_key,
    'handoff:' || left(p_handoff_id,120),
    'worker_handoff',
    left(p_handoff_id,200),
    jsonb_build_object('actions',coalesce(p_actions,'[]'::jsonb),'metadata',coalesce(p_metadata,'{}'::jsonb)),
    v_source
  );

  if coalesce((v_signal->>'inserted')::boolean,false) = false then
    return jsonb_build_object('ok',true,'deduplicated',true,'created',0,'signal',v_signal);
  end if;

  select coalesce(max(stage),0)+1 into v_stage
  from public.contentflow_build_backlog
  where project_key=p_project_key;

  for v_action in select trim(value) from jsonb_array_elements_text(coalesce(p_actions,'[]'::jsonb))
  loop
    v_idx := v_idx + 1;
    if v_action = '' then continue; end if;
    v_task_key := 'handoff_' || substr(md5(p_handoff_id),1,12) || '_' || lpad(v_idx::text,2,'0');

    insert into public.contentflow_build_backlog(
      project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,acceptance_criteria,execution_lane,workflow_state
    ) values (
      p_project_key,
      'external_handoff',
      v_task_key,
      left(v_action,180),
      v_action || E'\n\nHandoff: ' || p_handoff_id || E'\nSource: ' || v_source || E'\nMetadata: ' || coalesce(p_metadata,'{}'::jsonb)::text,
      'general',
      v_stage,
      '[]'::jsonb,
      'handoff:' || v_source,
      'ready',
      least(30,10+v_idx),
      'Return evidence-backed DONE/BLOCKED/PARTIAL status, concrete next action, and never invent external authorization or write evidence.',
      'llm_artifact',
      'artifact_pending'
    ) on conflict(project_key,task_key) do nothing;
    if found then
      v_created := v_created + 1;
      insert into public.director_project_task_scope(project_key,task_key,scope_class,counts_toward_progress,reason)
      values(p_project_key,v_task_key,'product',true,'durable worker handoff continuation')
      on conflict(project_key,task_key) do update set counts_toward_progress=true,reason=excluded.reason,updated_at=now();
    end if;
  end loop;

  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at)
  values(p_project_key,'handoff_ingested',v_source,'durable_handoff_bridge',case when v_created>0 then 'work_released' else 'no_actions' end,false,
    jsonb_build_object('handoff_id',p_handoff_id,'created',v_created,'action_count',jsonb_array_length(coalesce(p_actions,'[]'::jsonb)),'metadata',coalesce(p_metadata,'{}'::jsonb))::text,now());

  return jsonb_build_object('ok',true,'deduplicated',false,'created',v_created,'signal',v_signal);
end
$function$;

revoke all on function public.contentflow_ingest_handoff_v1(text,text,text,jsonb,jsonb) from public, anon, authenticated;
grant execute on function public.contentflow_ingest_handoff_v1(text,text,text,jsonb,jsonb) to service_role;
