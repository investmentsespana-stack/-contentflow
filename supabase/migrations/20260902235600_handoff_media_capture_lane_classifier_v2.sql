-- Root fix: external Social Ops handoffs that require authentic media capture/render/QA
-- must never be dispatched as generic LLM artifacts.
create or replace function public.contentflow_ingest_handoff_v1(p_project_key text, p_handoff_id text, p_source text, p_actions jsonb, p_metadata jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_signal jsonb; v_action text; v_idx int:=0; v_created int:=0; v_stage int:=1; v_task_key text;
  v_source text:=coalesce(nullif(trim(p_source),''),'external_handoff');
  v_context text:=left(coalesce(p_metadata->>'handoff_context',''),24000);
  v_files text:=coalesce((p_metadata->'files')::text,'[]');
  v_lane text; v_workflow_state text; v_blocked_reason text;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;
  if coalesce(trim(p_project_key),'')='' or coalesce(trim(p_handoff_id),'')='' then raise exception 'handoff_identity_required'; end if;
  if jsonb_typeof(coalesce(p_actions,'[]'::jsonb))<>'array' then raise exception 'handoff_actions_must_be_array'; end if;
  if jsonb_array_length(coalesce(p_actions,'[]'::jsonb))>20 then raise exception 'handoff_actions_limit_exceeded'; end if;
  v_signal:=public.contentflow_record_durable_signal_v1(p_project_key,'handoff:'||left(p_handoff_id,120),'worker_handoff',left(p_handoff_id,200),jsonb_build_object('actions',coalesce(p_actions,'[]'::jsonb),'metadata',coalesce(p_metadata,'{}'::jsonb)),v_source);
  if coalesce((v_signal->>'inserted')::boolean,false)=false then return jsonb_build_object('ok',true,'deduplicated',true,'created',0,'signal',v_signal); end if;
  select coalesce(max(stage),0)+1 into v_stage from public.contentflow_build_backlog where project_key=p_project_key;
  for v_action in select trim(value) from jsonb_array_elements_text(coalesce(p_actions,'[]'::jsonb)) loop
    v_idx:=v_idx+1; if v_action='' then continue; end if;
    v_task_key:='handoff_'||substr(md5(p_handoff_id),1,12)||'_'||lpad(v_idx::text,2,'0');
    if public.contentflow_evidence_prerequisite_class('other',v_action)='media_capture'
       or lower(v_action) ~ '(capture|render|mp4|keyframe|subtitle|sha-256|sha256|screen recording|qa receipt|lipsync|audiovisual|short variant|master premium|real screen)' then
      v_lane:='evidence_producer'; v_workflow_state:='evidence_pending'; v_blocked_reason:='MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE';
    else
      v_lane:='llm_artifact'; v_workflow_state:='artifact_pending'; v_blocked_reason:=null;
    end if;
    insert into public.contentflow_build_backlog(project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,acceptance_criteria,execution_lane,workflow_state,blocked_reason)
    values(p_project_key,'external_handoff',v_task_key,left(v_action,180),
      v_action||E'\n\nSOURCE HANDOFF CONTEXT (authoritative):\n'||case when v_context<>'' then v_context else '[context_not_embedded]' end||E'\n\nSource files: '||v_files||E'\nHandoff: '||p_handoff_id||E'\nSource: '||v_source||E'\nMetadata: '||coalesce(p_metadata,'{}'::jsonb)::text,
      'general',v_stage,'[]'::jsonb,'social-ops:'||v_source,case when v_lane='evidence_producer' then 'blocked' else 'ready' end,least(30,10+v_idx),
      'Use the embedded handoff context as authoritative source. Return evidence-backed DONE/BLOCKED/PARTIAL, cite exact repo paths/IDs present in context, identify any human gate, and never invent external authorization or write evidence.',
      v_lane,v_workflow_state,v_blocked_reason) on conflict(project_key,task_key) do nothing;
    if found then v_created:=v_created+1; insert into public.director_project_task_scope(project_key,task_key,scope_class,counts_toward_progress,reason) values(p_project_key,v_task_key,'product',true,'durable Social Ops handoff continuation with embedded context') on conflict(project_key,task_key) do update set counts_toward_progress=true,reason=excluded.reason,updated_at=now(); end if;
  end loop;
  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes,finished_at) values(p_project_key,'handoff_ingested',v_source,'durable_handoff_bridge_v3_media_lane',case when v_created>0 then 'work_released' else 'no_actions' end,false,jsonb_build_object('handoff_id',p_handoff_id,'created',v_created,'action_count',jsonb_array_length(coalesce(p_actions,'[]'::jsonb)),'context_bytes',length(v_context),'metadata',coalesce(p_metadata,'{}'::jsonb))::text,now());
  return jsonb_build_object('ok',true,'deduplicated',false,'created',v_created,'signal',v_signal,'context_bytes',length(v_context));
end$function$;

update public.contentflow_builder_runs r
set status='deferred',finished_at=now(),error='rerouted_to_media_capture_lane_v2',lease_revoked_at=now()
from public.contentflow_build_backlog b
where b.id=r.backlog_task_id and b.project_key='contentflow' and b.task_key like 'handoff_beadbe9291de_%'
  and r.status in ('claimed','running') and r.finished_at is null;

update public.director_worker_queue q
set status='ready',current_task_key=null,updated_at=now()
where q.current_task_key like 'handoff_beadbe9291de_%';

update public.contentflow_build_backlog b
set status='blocked',blocked_reason='MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE',execution_lane='evidence_producer',workflow_state='evidence_pending',selected_model=null,updated_at=now()
where b.project_key='contentflow' and b.task_key like 'handoff_beadbe9291de_%'
  and (public.contentflow_evidence_prerequisite_class('other',coalesce(b.title,'')||' '||coalesce(b.description,''))='media_capture'
       or lower(coalesce(b.title,'')||' '||coalesce(b.description,'')) ~ '(capture|render|mp4|keyframe|subtitle|sha-256|sha256|screen recording|qa receipt|lipsync|audiovisual|short variant|master premium|real screen)');

update public.contentflow_retry_state rs
set circuit_state='closed',circuit_open_until=null,next_retry_at=null,updated_at=now()
from public.contentflow_build_backlog b
where b.id=rs.backlog_task_id and b.project_key='contentflow' and b.task_key like 'handoff_beadbe9291de_%'
  and b.execution_lane='evidence_producer';