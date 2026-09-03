-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.academy_social_source_evidence_task_v4(p_kind text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_run_id bigint;
  v_events jsonb := '[]'::jsonb;
  v_cycles jsonb := '[]'::jsonb;
  v_workers jsonb := '[]'::jsonb;
  v_recent_runs jsonb := '[]'::jsonb;
  v_judge_pass boolean := false;
  v_runner_pass boolean := false;
begin
  if p_kind = 'f09' then
    select r.id into v_run_id
    from public.contentflow_builder_runs r
    where r.project_key='agent-academy-platform-v1'
      and r.task_key='academy_social_director_control_v3'
      and r.review_approved=true
      and r.quality_score>=95
    order by r.id desc limit 1;

    if v_run_id is null then
      raise exception 'F09_VERIFIED_DIRECTOR_RUN_NOT_FOUND';
    end if;

    select coalesce(jsonb_agg(jsonb_build_object(
      'event_type',e.event_type,
      'actor',e.actor,
      'created_at',e.created_at,
      'payload',e.payload
    ) order by e.created_at),'[]'::jsonb),
    coalesce(bool_or((e.payload->>'pass')::boolean) filter(where e.event_type='judge_completed'),false),
    coalesce(bool_or((e.payload->>'pass')::boolean) filter(where e.event_type='runner_completed'),false)
    into v_events,v_judge_pass,v_runner_pass
    from public.contentflow_runtime_event_ledger e
    where e.builder_run_id=v_run_id
      and e.event_type in ('claimed','executor_async_accepted','runner_v3_started','nexo_execution_probe','model_catalog_failover','artifact_generated','judge_completed','runner_completed','owner_finalized');

    if jsonb_array_length(v_events)<5 or not v_judge_pass or not v_runner_pass then
      raise exception 'F09_DIRECTOR_EVENT_CHAIN_INCOMPLETE';
    end if;

    return jsonb_build_object(
      'ok',true,
      'architecture','ACADEMY_SOCIAL_VERIFIED_SOURCE_EVIDENCE_V4',
      'evidence_kind','F09_director_orchestrator_coordination_capture_v1',
      'source','contentflow_runtime_event_ledger',
      'builder_run_id',v_run_id,
      'judge_pass',v_judge_pass,
      'runner_pass',v_runner_pass,
      'events',v_events,
      'sanitized',true,
      'publication_authorized',false,
      'generated_at',now()
    );
  elsif p_kind = 'f06' then
    select coalesce(jsonb_agg(x.obj order by x.id desc),'[]'::jsonb)
      into v_cycles
    from (
      select c.id,jsonb_build_object(
        'cycle_id',c.id,
        'project_key',c.project_key,
        'status',c.status,
        'dispatched',c.dispatched,
        'started_at',c.started_at,
        'finished_at',c.finished_at,
        'workers_ready',coalesce((c.pre_state->>'workers_ready')::int,0),
        'workers_running_before',coalesce((c.pre_state->>'workers_running')::int,0),
        'dispatchable_before',coalesce((c.pre_state->>'dispatchable')::int,0),
        'workers_running_after',coalesce((c.post_state->>'workers_running')::int,0),
        'dispatchable_after',coalesce((c.post_state->>'dispatchable')::int,0),
        'capacity_respected',coalesce((c.post_state->>'capacity_respected')::boolean,false),
        'active_state_mismatches',coalesce((c.post_state->>'active_state_mismatches')::int,0)
      ) obj
      from public.director_cycle_runs c
      where c.project_key in ('contentflow','agent-academy-platform-v1')
        and c.status in ('completed','completed_with_warnings')
        and c.started_at > now()-interval '24 hours'
      order by c.id desc
      limit 8
    ) x;

    select coalesce(jsonb_agg(jsonb_build_object(
      'model_id',q.model_id,
      'status',q.status,
      'last_task_key',q.last_task_key,
      'last_outcome',q.last_outcome,
      'last_quality_score',q.last_quality_score,
      'total_assignments',q.total_assignments,
      'total_completions',q.total_completions,
      'total_failures',q.total_failures,
      'updated_at',q.updated_at
    ) order by q.model_id),'[]'::jsonb)
    into v_workers
    from public.director_worker_queue q
    where q.status in ('ready','running');

    select coalesce(jsonb_agg(jsonb_build_object(
      'run_id',r.id,
      'task_key',r.task_key,
      'status',r.status,
      'selected_model',r.selected_model,
      'quality_score',r.quality_score,
      'review_approved',r.review_approved,
      'created_at',r.created_at,
      'finished_at',r.finished_at
    ) order by r.id desc),'[]'::jsonb)
    into v_recent_runs
    from (
      select r.*
      from public.contentflow_builder_runs r
      where r.project_key in ('contentflow','agent-academy-platform-v1')
        and r.created_at > now()-interval '24 hours'
        and r.status in ('completed','verification_required','failed')
      order by r.id desc limit 12
    ) r;

    if jsonb_array_length(v_cycles)=0 or jsonb_array_length(v_workers)=0 then
      raise exception 'F06_ROUTING_SOURCE_NOT_AVAILABLE';
    end if;

    return jsonb_build_object(
      'ok',true,
      'architecture','ACADEMY_SOCIAL_VERIFIED_SOURCE_EVIDENCE_V4',
      'evidence_kind','F06_capability_routing_workflow_capture_v1',
      'source','director_cycle_runs+director_worker_queue+contentflow_builder_runs',
      'cycles',v_cycles,
      'workers',v_workers,
      'recent_runs',v_recent_runs,
      'sanitized',true,
      'publication_authorized',false,
      'generated_at',now()
    );
  else
    raise exception 'UNSUPPORTED_EVIDENCE_KIND:%',p_kind;
  end if;
end
$function$;

update public.contentflow_build_backlog
set execution_lane='tool_executor',
    status='ready',
    blocked_reason=null,
    next_eligible_at=now(),
    completion_phase='runtime_verification',
    workflow_state='artifact_pending',
    selected_model=null,
    workflow_contract=jsonb_build_object(
      'contract_version','4',
      'runtime_required',true,
      'evidence_policy','deterministic_internal_source',
      'publication_authorized',false,
      'execution_recipe',jsonb_build_object(
        'handler','database_rpc',
        'rpc','academy_social_source_evidence_task_v4',
        'args',jsonb_build_object('p_kind',case task_key
          when 'academy_social_f06_verified_evidence_pack_v3' then 'f06'
          else 'f09' end),
        'deterministic',true
      )
    ),
    updated_at=now()
where project_key='agent-academy-platform-v1'
  and task_key in ('academy_social_f06_verified_evidence_pack_v3','academy_social_f09_verified_evidence_pack_v3');

delete from public.contentflow_retry_state
where project_key='agent-academy-platform-v1'
  and task_key in ('academy_social_f06_verified_evidence_pack_v3','academy_social_f09_verified_evidence_pack_v3');

update public.contentflow_tool_execution_queue q
set state='pending',last_error=null,claim_token=null,claimed_at=null,updated_at=now()
where q.project_key='agent-academy-platform-v1'
  and q.task_key in ('academy_social_f06_verified_evidence_pack_v3','academy_social_f09_verified_evidence_pack_v3')
  and q.state<>'completed';
