create or replace function public.contentflow_verified_external_evidence_context(p_project_key text, p_task_key text)
returns text
language sql
stable
set search_path to 'public'
as $function$
with direct_evidence as (
  select 1 as ord,e.created_at,e.id,
    format('DIRECT VERIFIED EVIDENCE | type=%s | status=%s | verified=%s | source=%s | evidence=%s',e.evidence_type,e.status,e.verified,coalesce(e.source,''),left(coalesce(e.evidence::text,'{}'),4000)) as ctx
  from public.director_external_evidence e
  where e.project_key=p_project_key and e.task_key=p_task_key and e.verified=true and e.status='pass'
), dependency_evidence as (
  select 2 as ord,d.updated_at as created_at,d.id,
    format('VERIFIED DEPENDENCY RUNTIME EVIDENCE | task=%s | title=%s | status=%s | runtime_verified=%s | completion_phase=%s | evidence=%s',d.task_key,coalesce(d.title,''),d.status,d.runtime_verified,coalesce(d.completion_phase,''),left(coalesce(d.runtime_evidence::text,'{}'),12000)) as ctx
  from public.contentflow_build_backlog t
  cross join lateral jsonb_array_elements_text(coalesce(t.depends_on,'[]'::jsonb)) dep(value)
  join public.contentflow_build_backlog d on d.project_key=t.project_key and d.task_key=dep.value
  where t.project_key=p_project_key and t.task_key=p_task_key and d.status='completed' and d.runtime_verified=true and coalesce(d.runtime_evidence,'{}'::jsonb) <> '{}'::jsonb
)
select string_agg(ctx,E'\n---\n' order by ord,created_at desc,id desc)
from (select * from direct_evidence union all select * from dependency_evidence) x;
$function$;
