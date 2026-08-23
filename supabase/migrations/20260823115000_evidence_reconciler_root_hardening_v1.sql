-- Root hardening for evidence reconciliation.
-- 1) One active requirement per backlog task + evidence class.
-- 2) Stable fingerprints independent of RARA wording.
-- 3) Verified evidence source correlation is immutable.
-- 4) Stale/orphan evidence dependencies are garbage-collected.
-- 5) Generic word "approval" no longer implies human/external approval.

with ranked as (
  select id,project_key,backlog_task_id,requirement_class,evidence_task_key,status,
         row_number() over(
           partition by project_key,backlog_task_id,requirement_class
           order by case when status='verified' then 0 else 1 end,id
         ) rn
  from public.contentflow_evidence_requirements
  where status<>'obsolete'
), losers as (
  select * from ranked where rn>1
)
update public.contentflow_evidence_requirements er
set status='obsolete',updated_at=now(),
    evidence_ref=coalesce(er.evidence_ref,'{}'::jsonb)||jsonb_build_object(
      'superseded_reason','semantic_duplicate','superseded_at',now()
    )
from losers l where er.id=l.id;

create unique index if not exists uq_contentflow_evidence_semantic_identity
on public.contentflow_evidence_requirements(project_key,backlog_task_id,requirement_class)
where status<>'obsolete';

create or replace function public.contentflow_evidence_requirement_class(p_error text)
returns text
language sql
immutable
set search_path='public','pg_temp'
as $function$
  select case
    when coalesce(p_error,'') ~* 'static analysis|mypy|lint|scanner|entropy scanner' then 'static_analysis'
    when coalesce(p_error,'') ~* 'test corpus|test suite|integration test|unit test|test execution|false negative|end-to-end test|e2e test' then 'runtime_test'
    when coalesce(p_error,'') ~* 'PlatformStore|persisted evidence|record_evidence|evidence store|database record|durable storage|runtime log|persisted runtime' then 'persistence_integration'
    when coalesce(p_error,'') ~* 'missing method|interface|contract|schema|field|signature not verified|method signature' then 'source_contract'
    when coalesce(p_error,'') ~* '(human|owner|security team|architecture team|external)[ -]?(approval|sign.?off|authorization)|requires? (manual|human) approval|pending owner decision' then 'external_approval'
    when coalesce(p_error,'') ~* 'NEEDS_EVIDENCE|missing evidence|no persisted runtime evidence|RARA_REVIEW_REJECTED' then 'runtime_evidence'
    else 'unknown'
  end
$function$;

create or replace function public.contentflow_gc_evidence_dependencies(p_project_key text default 'contentflow')
returns jsonb
language plpgsql
security definer
set search_path='public'
as $function$
declare v_removed int:=0; v_retired int:=0; v_reopened int:=0;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then
    raise exception 'privileged_channel_required';
  end if;

  with cleaned as (
    select b.id,
           coalesce((
             select jsonb_agg(d.value)
             from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value)
             left join public.contentflow_build_backlog e
               on e.project_key=b.project_key and e.task_key=d.value
             where not (
               d.value like 'evidence_%'
               and coalesce(e.status,'missing')<>'completed'
               and not exists (
                 select 1
                 from public.contentflow_evidence_requirements er
                 where er.project_key=b.project_key
                   and er.evidence_task_key=d.value
                   and er.status in ('task_created','open','blocked')
               )
             )
           ),'[]'::jsonb) new_depends
    from public.contentflow_build_backlog b
    where b.project_key=p_project_key
  )
  update public.contentflow_build_backlog b
     set depends_on=c.new_depends,updated_at=now()
    from cleaned c
   where b.id=c.id and b.depends_on is distinct from c.new_depends;
  get diagnostics v_removed=row_count;

  update public.contentflow_build_backlog e
     set status='deferred',completion_phase='orphan_evidence_retired',next_eligible_at=null,updated_at=now()
   where e.project_key=p_project_key
     and e.task_key like 'evidence_%'
     and e.status<>'completed'
     and not exists (
       select 1 from public.contentflow_evidence_requirements er
       where er.project_key=e.project_key and er.evidence_task_key=e.task_key
         and er.status in ('task_created','open','blocked')
     );
  get diagnostics v_retired=row_count;

  update public.contentflow_build_backlog b
     set status='ready',next_eligible_at=now(),updated_at=now()
   where b.project_key=p_project_key and b.status='blocked'
     and b.completion_phase in ('waiting_for_evidence','evidence_verified')
     and not exists (
       select 1 from public.contentflow_evidence_requirements er
       where er.backlog_task_id=b.id and er.status not in ('verified','obsolete')
     )
     and not exists (
       select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value)
       where not exists (
         select 1 from public.contentflow_build_backlog dep
         where dep.project_key=b.project_key and dep.task_key=d.value and dep.status='completed'
       )
     )
     and not exists (
       select 1 from public.contentflow_builder_runs r
       where r.backlog_task_id=b.id and r.status in ('claimed','running','review_required') and r.finished_at is null
     );
  get diagnostics v_reopened=row_count;

  return jsonb_build_object(
    'architecture','EVIDENCE_DEPENDENCY_GC_V1',
    'tasks_dependencies_rewritten',v_removed,
    'orphan_evidence_tasks_retired',v_retired,
    'originals_reopened',v_reopened
  );
end
$function$;

create or replace function public.contentflow_reconcile_ready_after_evidence(p_project_key text default 'contentflow')
returns jsonb language plpgsql security definer set search_path='public'
as $function$
declare v_ready int:=0;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then
    raise exception 'privileged_channel_required';
  end if;
  update public.contentflow_build_backlog b
     set status='ready',next_eligible_at=now(),updated_at=now()
   where b.project_key=p_project_key and b.status='blocked' and b.completion_phase='evidence_verified'
     and not exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.status in ('claimed','running','review_required') and r.finished_at is null)
     and not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(value) where not exists(select 1 from public.contentflow_build_backlog dep where dep.project_key=b.project_key and dep.task_key=d.value and dep.status='completed'));
  get diagnostics v_ready=row_count;
  return jsonb_build_object('architecture','READY_AFTER_EVIDENCE_V1','reopened',v_ready);
end
$function$;
