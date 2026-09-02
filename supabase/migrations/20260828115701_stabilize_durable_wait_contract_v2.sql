-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_reconcile_durable_waits_v1(p_project_key text default 'contentflow'::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  x record;
  v_kind text;
  v_key text;
  v_wake timestamptz;
  v_terminal text;
  v_state text;
  v_classified int:=0;
  v_released int:=0;
  v_unclassified int:=0;
  v_incidents int:=0;
  v_terminal_classified int:=0;
  v_satisfied_dependencies int:=0;
  v_existing_incident bigint;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then
    raise exception 'service_role_required';
  end if;

  for x in
    select b.*,
      (select min(rs.next_retry_at) from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.next_retry_at is not null) retry_at,
      (select min(rs.circuit_open_until) from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open' and rs.circuit_open_until is not null) circuit_until
    from public.contentflow_build_backlog b
    where b.project_key=p_project_key and b.status='deferred'
  loop
    v_kind:=null; v_key:=null; v_wake:=null; v_terminal:=null; v_state:='waiting';

    -- Structural terminal states are not waits and must never generate recovery incidents.
    if coalesce(x.blocked_reason,'') ilike 'OBSOLETE%'
       or coalesce(x.workflow_state,'')='obsolete'
       or coalesce(x.team,'') in ('invalid_recursive_gap','bootstrap_recursive_evidence_obsolete') then
      v_kind:='terminal';
      v_terminal:=case
        when coalesce(x.blocked_reason,'') ilike 'OBSOLETE%' then x.blocked_reason
        when coalesce(x.workflow_state,'')='obsolete' then 'OBSOLETE_WORKFLOW_STATE'
        when coalesce(x.team,'')='invalid_recursive_gap' then 'INVALID_RECURSIVE_GAP_TERMINAL'
        else 'BOOTSTRAP_RECURSIVE_EVIDENCE_OBSOLETE'
      end;
      v_key:=lower(v_terminal);
      v_state:='terminal';
      v_terminal_classified:=v_terminal_classified+1;

    elsif x.next_eligible_at is not null and x.next_eligible_at>now() then
      v_kind:=case when x.retry_at is not null or x.circuit_until is not null then 'retry' else 'timer' end;
      v_wake:=greatest(x.next_eligible_at,coalesce(x.retry_at,x.next_eligible_at),coalesce(x.circuit_until,x.next_eligible_at));
      v_key:=coalesce(x.blocked_reason,'scheduled_wakeup');

    -- A deferred task whose declared dependencies are all completed is releasable now.
    elsif jsonb_array_length(coalesce(x.depends_on,'[]'::jsonb))>0
      and not exists(
        select 1
        from jsonb_array_elements_text(coalesce(x.depends_on,'[]'::jsonb)) d(dep)
        where not exists(
          select 1 from public.contentflow_build_backlog z
          where z.project_key=x.project_key and z.task_key=d.dep and z.status='completed'
        )
      ) then
      v_kind:='dependency';
      v_key:='all_dependencies_satisfied';
      v_state:='released';
      v_satisfied_dependencies:=v_satisfied_dependencies+1;

    elsif exists(
      select 1 from jsonb_array_elements_text(coalesce(x.depends_on,'[]'::jsonb)) d(dep)
      where not exists(
        select 1 from public.contentflow_build_backlog z
        where z.project_key=x.project_key and z.task_key=d.dep and z.status='completed'
      )
    ) then
      v_kind:='dependency';
      select d.dep into v_key
      from jsonb_array_elements_text(coalesce(x.depends_on,'[]'::jsonb)) d(dep)
      where not exists(
        select 1 from public.contentflow_build_backlog z
        where z.project_key=x.project_key and z.task_key=d.dep and z.status='completed'
      )
      order by d.dep limit 1;

    elsif x.retry_at is not null or x.circuit_until is not null then
      v_kind:='retry';
      v_wake:=greatest(coalesce(x.retry_at,'-infinity'::timestamptz),coalesce(x.circuit_until,'-infinity'::timestamptz));
      v_key:='retry_policy';

    elsif coalesce(x.execution_lane,'llm_artifact') in ('tool_executor','evidence_producer')
      and not public.contentflow_tool_execution_capability_ready(x.project_key,x.task_key) then
      v_kind:='capability';
      v_key:=coalesce(x.execution_lane,'evidence_producer');

    elsif exists(
      select 1 from public.contentflow_review_work_queue q
      join public.contentflow_builder_runs r on r.id=q.builder_run_id
      where r.backlog_task_id=x.id and q.state in ('pending','claimed')
    ) then
      v_kind:='review';
      v_key:='rara_review';

    else
      v_kind:='unclassified';
      v_state:='unclassified';
      v_key:='missing_causal_wakeup';
      v_unclassified:=v_unclassified+1;
    end if;

    insert into public.contentflow_wait_registry(
      backlog_task_id,project_key,task_key,wait_kind,wait_key,wake_at,terminal_reason,state,
      evidence,released_at,updated_at
    ) values(
      x.id,x.project_key,x.task_key,v_kind,v_key,v_wake,v_terminal,v_state,
      jsonb_build_object(
        'status',x.status,'workflow_state',x.workflow_state,'blocked_reason',x.blocked_reason,
        'team',x.team,'classified_from','durable_wait_signal_contract_v2'
      ),
      case when v_state='released' then now() else null end,
      now()
    )
    on conflict(backlog_task_id) do update set
      wait_kind=excluded.wait_kind,
      wait_key=excluded.wait_key,
      wake_at=excluded.wake_at,
      terminal_reason=excluded.terminal_reason,
      generation=case
        when public.contentflow_wait_registry.wait_kind is distinct from excluded.wait_kind
          or public.contentflow_wait_registry.wait_key is distinct from excluded.wait_key
          or public.contentflow_wait_registry.wake_at is distinct from excluded.wake_at
        then public.contentflow_wait_registry.generation+1
        else public.contentflow_wait_registry.generation
      end,
      state=excluded.state,
      classified_at=case
        when public.contentflow_wait_registry.wait_kind is distinct from excluded.wait_kind then now()
        else public.contentflow_wait_registry.classified_at
      end,
      released_at=excluded.released_at,
      evidence=public.contentflow_wait_registry.evidence||excluded.evidence,
      updated_at=now();
    v_classified:=v_classified+1;
  end loop;

  update public.contentflow_wait_registry w
  set state='released',released_at=now(),updated_at=now()
  where w.project_key=p_project_key and w.state='waiting' and exists(
    select 1 from public.contentflow_build_backlog b
    where b.id=w.backlog_task_id and b.status='deferred' and (
      (w.wait_kind in ('timer','retry') and w.wake_at is not null and w.wake_at<=now()
       and not exists(select 1 from public.contentflow_retry_state rs where rs.backlog_task_id=b.id and rs.circuit_state='open' and coalesce(rs.circuit_open_until,now()+interval '1 day')>now()))
      or (w.wait_kind='dependency' and not exists(
        select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(dep)
        where not exists(select 1 from public.contentflow_build_backlog z where z.project_key=b.project_key and z.task_key=d.dep and z.status='completed')
      ))
      or (w.wait_kind='capability' and public.contentflow_tool_execution_capability_ready(b.project_key,b.task_key))
      or (w.wait_kind='external_signal' and exists(select 1 from public.contentflow_durable_signal_ledger s where s.project_key=b.project_key and s.task_key=b.task_key and s.signal_key=w.wait_key))
    )
  );
  get diagnostics v_released=row_count;

  update public.contentflow_build_backlog b
  set status='ready',blocked_reason=null,next_eligible_at=now(),updated_at=now()
  where b.project_key=p_project_key and b.status='deferred'
    and exists(
      select 1 from public.contentflow_wait_registry w
      where w.backlog_task_id=b.id and w.state='released' and w.released_at>=now()-interval '2 minutes'
    );

  -- Keep one canonical incident row. Never create one incident per control-loop cycle.
  select id into v_existing_incident
  from public.director_repair_incidents
  where project_key=p_project_key and error_fingerprint='durable_wait_unclassified:v2'
  order by id desc limit 1;

  if v_unclassified>0 then
    if v_existing_incident is null then
      insert into public.director_repair_incidents(
        project_key,component,error_class,error_fingerprint,symptom,evidence,risk_level,status,
        max_attempts,requires_human,root_cause,proposed_action
      ) values(
        p_project_key,'director_control','durable_wait_unclassified','durable_wait_unclassified:v2',
        'Deferred work remains without a durable exit contract after terminal/dependency normalization',
        jsonb_build_object('unclassified',v_unclassified,'architecture','DURABLE_WAIT_SIGNAL_CONTRACT_V2'),
        'medium','open',3,false,
        'Planner emitted deferred work without timer, unresolved dependency, retry, capability, review, external signal, or structural terminal marker',
        'Classify the originating planner contract; do not redispatch blindly'
      );
      v_incidents:=1;
    else
      update public.director_repair_incidents
      set evidence=jsonb_build_object('unclassified',v_unclassified,'architecture','DURABLE_WAIT_SIGNAL_CONTRACT_V2'),
          symptom='Deferred work remains without a durable exit contract after terminal/dependency normalization',
          updated_at=now(),
          requires_human=false
      where id=v_existing_incident;
    end if;
  elsif v_existing_incident is not null then
    update public.director_repair_incidents
    set status='resolved',resolved_at=coalesce(resolved_at,now()),updated_at=now(),requires_human=false,
        outcome='all_deferred_work_has_durable_exit_contract'
    where id=v_existing_incident and status<>'resolved';
  end if;

  update public.contentflow_wait_registry w
  set state='released',released_at=coalesce(released_at,now()),updated_at=now()
  where w.project_key=p_project_key and w.state in ('waiting','unclassified')
    and exists(select 1 from public.contentflow_build_backlog b where b.id=w.backlog_task_id and b.status<>'deferred');

  return jsonb_build_object(
    'architecture','DURABLE_WAIT_SIGNAL_CONTRACT_V2',
    'classified',v_classified,
    'terminal_classified',v_terminal_classified,
    'satisfied_dependency_releases',v_satisfied_dependencies,
    'released',v_released,
    'unclassified',v_unclassified,
    'incident_created',v_incidents,
    'waiting',(select count(*) from public.contentflow_wait_registry where project_key=p_project_key and state='waiting'),
    'terminal',(select count(*) from public.contentflow_wait_registry where project_key=p_project_key and state='terminal')
  );
end
$function$;

insert into public.director_error_memory(
  project_key,error_class,error_fingerprint,component,symptom,root_cause,correction,prevention_rule,
  evidence,occurrences,correction_successes,correction_failures,confidence,status,last_seen_at,updated_at
) values(
  'contentflow','durable_wait_classification','durable_wait_signal_contract_v2','director_control',
  'Deferred structural-terminal and already-satisfied dependency work was repeatedly reported as durable_wait_unclassified.',
  'The durable-wait classifier lacked structural terminal markers and an immediate release state for completed dependencies; the aggregate incident could be recreated after resolution.',
  'DURABLE_WAIT_SIGNAL_CONTRACT_V2: classify recursive/obsolete work as terminal, release satisfied dependencies, preserve genuine capability waits, and maintain one canonical unclassified incident.',
  'Every deferred task must have exactly one durable exit contract. Recursive/obsolete markers are terminal; completed dependencies release immediately; a repeated control-loop pass must not create duplicate incidents.',
  '{"migration":"stabilize_durable_wait_contract_v2"}',1,0,0,0.80,'active',now(),now()
)
on conflict(project_key,error_fingerprint) do update set
  root_cause=excluded.root_cause,correction=excluded.correction,prevention_rule=excluded.prevention_rule,
  evidence=excluded.evidence,occurrences=public.director_error_memory.occurrences+1,last_seen_at=now(),updated_at=now(),status='active';
