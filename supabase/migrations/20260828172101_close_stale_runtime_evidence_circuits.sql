-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

CREATE OR REPLACE FUNCTION public.contentflow_reconcile_retry_policies(p_project_key text DEFAULT 'contentflow'::text, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare x record; n int:=0; scheduled int:=0; blocked int:=0; a jsonb; cleaned int:=0; stale_runtime_closed int:=0;
begin
  with obsolete as (
    select s.backlog_task_id
    from public.contentflow_retry_state s
    join public.contentflow_build_backlog b on b.id=s.backlog_task_id
    left join public.contentflow_builder_runs lr on lr.id=s.last_run_id
    where s.project_key=p_project_key
      and (
        b.status='completed'
        or coalesce(b.workflow_state,'')='superseded'
        or coalesce(b.blocked_reason,'') like 'SUPERSEDED_BY_%'
        or lr.id is null
        or lr.status not in ('failed','deferred')
        or exists(select 1 from public.contentflow_builder_runs newer where newer.backlog_task_id=s.backlog_task_id and newer.id>s.last_run_id)
        or (
          coalesce(b.epic,'') in ('evidence_capability','evidence_capability_root','capability_bootstrap')
          and b.status in ('ready','planned')
          and lr.finished_at is not null
          and b.updated_at>lr.finished_at
        )
      )
  )
  delete from public.contentflow_retry_state s using obsolete o where s.backlog_task_id=o.backlog_task_id;
  get diagnostics cleaned=row_count;

  update public.contentflow_build_backlog
     set status='deferred', next_eligible_at=null, updated_at=now()
   where project_key=p_project_key
     and (coalesce(workflow_state,'')='superseded' or coalesce(blocked_reason,'') like 'SUPERSEDED_BY_%')
     and status<>'deferred';

  /* A failed LLM task may open a circuit because required runtime evidence did not yet exist.
     Once dependencies are complete and newer verified runtime evidence has arrived, that
     circuit is stale and must not permanently suppress an otherwise dispatchable task. */
  update public.contentflow_retry_state s
     set circuit_state='closed', circuit_open_until=null, next_retry_at=now(), updated_at=now()
    from public.contentflow_build_backlog b,
         public.contentflow_builder_runs lr
   where s.project_key=p_project_key
     and s.backlog_task_id=b.id
     and lr.id=s.last_run_id
     and s.circuit_state='open'
     and b.status in ('ready','planned')
     and lr.status in ('failed','deferred')
     and lr.finished_at is not null
     and b.updated_at>lr.finished_at
     and coalesce(s.last_error,'') ilike 'Missing verified runtime evidence%'
     and not exists (
       select 1
       from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
       where not exists (
         select 1 from public.contentflow_build_backlog d
         where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'
       )
     )
     and exists (
       select 1
       from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
       join public.contentflow_build_backlog d
         on d.project_key=b.project_key and d.task_key=dep.value
       where d.status='completed' and d.runtime_verified=true and d.updated_at>lr.finished_at
     );
  get diagnostics stale_runtime_closed=row_count;

  for x in
    select r.id
    from public.contentflow_builder_runs r
    join public.contentflow_build_backlog b on b.id=r.backlog_task_id
    left join public.contentflow_retry_state s on s.backlog_task_id=b.id
    where r.project_key=p_project_key
      and b.status<>'completed'
      and coalesce(b.workflow_state,'')<>'superseded'
      and coalesce(b.blocked_reason,'') not like 'SUPERSEDED_BY_%'
      and r.status in ('failed','deferred') and r.finished_at is not null
      and s.last_run_id is distinct from r.id
      and r.id=(select max(z.id) from public.contentflow_builder_runs z where z.backlog_task_id=r.backlog_task_id and z.finished_at is not null)
      and not exists(
        select 1 from public.contentflow_builder_runs active
        where active.backlog_task_id=b.id and active.status in ('claimed','running','review_required','verification_required') and active.finished_at is null
      )
      and not (
        coalesce(b.epic,'') in ('evidence_capability','evidence_capability_root','capability_bootstrap')
        and b.status in ('ready','planned')
        and b.updated_at>r.finished_at
      )
    order by r.id asc limit greatest(1,least(coalesce(p_limit,100),500))
  loop
    a:=public.contentflow_apply_retry_policy(x.id); n:=n+1;
    if a->>'action'='retry_scheduled' then scheduled:=scheduled+1; elsif a->>'action'='blocked_for_repair' then blocked:=blocked+1; end if;
  end loop;
  update public.contentflow_retry_state set circuit_state='closed',circuit_open_until=null where project_key=p_project_key and circuit_state='cooldown' and next_retry_at<=now();
  return jsonb_build_object('examined',n,'scheduled',scheduled,'blocked',blocked,'obsolete_cleaned',cleaned,'stale_runtime_evidence_circuits_closed',stale_runtime_closed,'superseded_guard',true,'active_run_protected',true,'bootstrap_repair_protected',true);
end
$function$;
