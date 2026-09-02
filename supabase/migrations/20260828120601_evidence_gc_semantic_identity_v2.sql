-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_gc_evidence_dependencies(p_project_key text default 'contentflow'::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare v_removed int:=0; v_retired int:=0; v_reopened int:=0; v_false_tombstones_recovered int:=0;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then
    raise exception 'privileged_channel_required';
  end if;

  -- Remove only dependencies that are semantically evidence activities.
  -- A textual evidence_ prefix alone is not evidence identity.
  with cleaned as (
    select b.id,
           coalesce((select jsonb_agg(d.value order by d.ord)
                     from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) with ordinality d(value,ord)
                     left join public.contentflow_build_backlog e
                       on e.project_key=b.project_key and e.task_key=d.value
                     where not (
                       e.id is not null
                       and (
                         coalesce(e.epic,'')='evidence_first'
                         or coalesce(e.execution_lane,'')='evidence_producer'
                         or exists(
                           select 1 from public.contentflow_evidence_requirements er0
                           where er0.project_key=e.project_key and er0.evidence_task_key=e.task_key
                         )
                       )
                       and coalesce(e.status,'missing')<>'completed'
                       and not exists (
                         select 1 from public.contentflow_evidence_requirements er
                         where er.project_key=b.project_key and er.evidence_task_key=d.value
                           and er.status in ('task_created','open','blocked')
                       )
                     )),'[]'::jsonb) new_depends
    from public.contentflow_build_backlog b
    where b.project_key=p_project_key
  )
  update public.contentflow_build_backlog b
     set depends_on=c.new_depends,updated_at=now()
    from cleaned c
   where b.id=c.id and b.depends_on is distinct from c.new_depends;
  get diagnostics v_removed=row_count;

  -- Retire only genuine evidence activities with no active requirement.
  update public.contentflow_build_backlog e
     set status='deferred',completion_phase='orphan_evidence_retired',next_eligible_at=null,updated_at=now()
   where e.project_key=p_project_key
     and e.status<>'completed'
     and (
       coalesce(e.epic,'')='evidence_first'
       or coalesce(e.execution_lane,'')='evidence_producer'
       or exists(
         select 1 from public.contentflow_evidence_requirements er0
         where er0.project_key=e.project_key and er0.evidence_task_key=e.task_key
       )
     )
     and not exists(
       select 1 from public.contentflow_evidence_requirements er
       where er.project_key=e.project_key and er.evidence_task_key=e.task_key
         and er.status in ('task_created','open','blocked')
     );
  get diagnostics v_retired=row_count;

  -- Recover false tombstones created by the old prefix-only GC contract.
  update public.contentflow_build_backlog b
     set status='ready',
         completion_phase='artifact_pending',
         blocked_reason=null,
         next_eligible_at=now(),
         selected_model=null,
         updated_at=now()
   where b.project_key=p_project_key
     and b.status='deferred'
     and b.completion_phase='orphan_evidence_retired'
     and coalesce(b.execution_lane,'llm_artifact')='llm_artifact'
     and coalesce(b.epic,'')<>'evidence_first'
     and not exists(
       select 1 from public.contentflow_evidence_requirements er
       where er.project_key=b.project_key and er.evidence_task_key=b.task_key
     )
     and not exists(
       select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value)
       where not exists(
         select 1 from public.contentflow_build_backlog dep
         where dep.project_key=b.project_key and dep.task_key=d.value and dep.status='completed'
       )
     );
  get diagnostics v_false_tombstones_recovered=row_count;

  update public.contentflow_build_backlog b
     set status='ready',next_eligible_at=now(),completion_phase='evidence_verified',updated_at=now()
   where b.project_key=p_project_key and b.status='blocked' and b.completion_phase='waiting_for_evidence'
     and not exists(select 1 from public.contentflow_evidence_requirements er where er.backlog_task_id=b.id and er.status not in ('verified','obsolete'))
     and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value)
                    where not exists(select 1 from public.contentflow_build_backlog dep where dep.project_key=b.project_key and dep.task_key=d.value and dep.status='completed'))
     and not exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.status in ('claimed','running','review_required','verification_required') and r.finished_at is null);
  get diagnostics v_reopened=row_count;

  return jsonb_build_object(
    'architecture','EVIDENCE_DEPENDENCY_GC_V2_SEMANTIC_IDENTITY',
    'tasks_dependencies_rewritten',v_removed,
    'orphan_evidence_tasks_retired',v_retired,
    'false_prefix_tombstones_recovered',v_false_tombstones_recovered,
    'originals_reopened',v_reopened
  );
end
$function$;

insert into public.director_error_memory(
  project_key,error_class,error_fingerprint,component,symptom,root_cause,correction,prevention_rule,
  evidence,occurrences,correction_successes,correction_failures,confidence,status,last_seen_at,updated_at
) values(
  'contentflow','evidence_identity_collision','evidence_gc_prefix_collision_v1','evidence_control_plane',
  'LLM capacity-planning tasks named evidence_* were repeatedly tombstoned as orphan evidence and revived by normalization, preventing dispatch.',
  'Evidence GC used task_key prefix as identity instead of evidence requirement/lane/epic semantics.',
  'EVIDENCE_DEPENDENCY_GC_V2_SEMANTIC_IDENTITY: classify evidence by evidence_first epic, evidence_producer lane, or registered evidence requirement; recover false prefix tombstones.',
  'Never infer execution identity from a task-key prefix alone. Evidence lifecycle mutations require semantic identity from lane, epic, or persisted requirement.',
  '{"old_rule":"task_key like evidence_%","new_rule":"semantic evidence identity"}'::text,
  1,0,0,0.90,'active',now(),now()
)
on conflict(project_key,error_fingerprint) do update set
  occurrences=public.director_error_memory.occurrences+1,
  root_cause=excluded.root_cause,correction=excluded.correction,prevention_rule=excluded.prevention_rule,
  evidence=excluded.evidence,status='active',last_seen_at=now(),updated_at=now();
