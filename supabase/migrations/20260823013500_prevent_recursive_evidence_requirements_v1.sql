do $$
declare v_def text;
begin
  select pg_get_functiondef('public.contentflow_evidence_first_reconcile(text,integer)'::regprocedure) into v_def;
  if position('b.task_key not like ''evidence_%''' in v_def)=0 then
    v_def := replace(
      v_def,
      'and b.status <> ''completed''',
      'and b.status <> ''completed''' || chr(10) || '      and b.task_key not like ''evidence_%'''
    );
    execute v_def;
  end if;
end $$;

comment on function public.contentflow_evidence_first_reconcile(text,integer) is
'EVIDENCE_FIRST_EXECUTION_V1 with recursive evidence-of-evidence prevention: evidence_* tasks are terminal evidence producers and never generate child evidence requirements.';

-- Quarantine only recursively-created descendants and restore their first-level
-- evidence parents to the terminal evidence producer state. Preserve builder-run
-- history for auditability; do not fabricate completion.
with rr as (
  select id, backlog_task_id, evidence_task_key
  from public.contentflow_evidence_requirements
  where project_key='contentflow' and task_key like 'evidence_%'
), cleaned as (
  select b.id,
         coalesce((
           select jsonb_agg(v)
           from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) x(v)
           where not exists (
             select 1 from rr
             where rr.backlog_task_id=b.id and rr.evidence_task_key=x.v
           )
         ), '[]'::jsonb) as new_deps
  from public.contentflow_build_backlog b
  where b.id in (select backlog_task_id from rr)
)
update public.contentflow_build_backlog b
set depends_on=c.new_deps,
    status='blocked',
    completion_phase='evidence_required',
    next_eligible_at=null,
    selected_model=null,
    updated_at=now()
from cleaned c
where b.id=c.id and b.status<>'completed';

update public.contentflow_build_backlog b
set status='deferred',
    completion_phase='recursive_evidence_quarantined',
    next_eligible_at=null,
    selected_model=null,
    updated_at=now()
where b.project_key='contentflow'
  and b.task_key in (
    select evidence_task_key
    from public.contentflow_evidence_requirements
    where project_key='contentflow' and task_key like 'evidence_%'
  )
  and b.status<>'completed';

delete from public.contentflow_retry_state
where backlog_task_id in (
  select id from public.contentflow_build_backlog
  where project_key='contentflow' and task_key like 'evidence_evidence_%'
);

delete from public.contentflow_evidence_requirements
where project_key='contentflow' and task_key like 'evidence_%';
