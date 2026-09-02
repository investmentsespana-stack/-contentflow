-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.internal_builder_claim_next_task(p_project_key text default 'contentflow'::text)
returns table(id bigint, task_key text, title text, description text, task_type text, stage integer, priority integer, depends_on text[], acceptance_criteria text)
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if coalesce(auth.role(),'') <> 'service_role' then
    raise exception 'service_role_required';
  end if;
  if p_project_key not in ('contentflow','agent-academy-platform-v1') then
    raise exception 'builder_project_not_allowed';
  end if;
  return query
  with candidate as (
    select b1.id
    from public.contentflow_build_backlog b1
    where b1.project_key=p_project_key
      and b1.status in ('planned','ready')
      and coalesce(b1.execution_lane,'llm_artifact') = 'llm_artifact'
      and b1.task_key not like 'gap_gap_%'
      and (b1.next_eligible_at is null or b1.next_eligible_at <= now())
      and not exists (
        select 1 from public.contentflow_retry_state rs
        where rs.backlog_task_id=b1.id and rs.circuit_state='open'
      )
      and not exists (
        select 1
        from jsonb_array_elements_text(coalesce(b1.depends_on,'[]'::jsonb)) dep(value)
        where not exists (
          select 1 from public.contentflow_build_backlog d
          where d.project_key=b1.project_key and d.task_key=dep.value and d.status='completed'
        )
      )
    order by b1.stage asc,b1.priority desc,b1.id asc
    for update skip locked
    limit 1
  ), claimed as (
    update public.contentflow_build_backlog b2
    set status='running',updated_at=now()
    from candidate c
    where b2.id=c.id
    returning b2.*
  )
  select c2.id,c2.task_key,c2.title,c2.description,c2.task_type,c2.stage,c2.priority,
         array(select jsonb_array_elements_text(coalesce(c2.depends_on,'[]'::jsonb))),c2.acceptance_criteria
  from claimed c2;
end
$function$;
