create or replace function public.contentflow_evidence_coverage_plan(
  p_project_key text default 'contentflow'
)
returns table(
  requirement_id bigint,
  requirement_class text,
  task_key text,
  evidence_task_key text,
  prerequisite text,
  coverage_state text,
  priority_score integer,
  provider text,
  scope text
)
language sql
stable
security invoker
set search_path = 'public'
as $$
  select
    er.id as requirement_id,
    er.requirement_class,
    er.task_key,
    er.evidence_task_key,
    coalesce(m.prerequisite, 'other') as prerequisite,
    case
      when coalesce(m.evidence_already_verifiable, false) then 'ready_to_verify'
      when coalesce(m.producer_available, false) and coalesce(m.verifier_available, false) then 'producer_ready'
      when coalesce(m.verifier_available, false) then 'verifier_only'
      else 'missing_capability'
    end as coverage_state,
    (
      case er.requirement_class
        when 'runtime_test' then 60
        when 'persistence_integration' then 55
        when 'runtime_evidence' then 50
        when 'source_contract' then 45
        when 'static_analysis' then 40
        when 'external_approval' then 30
        else 25
      end
      +
      case
        when coalesce(m.evidence_already_verifiable, false) then 40
        when coalesce(m.producer_available, false) and coalesce(m.verifier_available, false) then 30
        when coalesce(m.verifier_available, false) then 20
        else 10
      end
    )::integer as priority_score,
    m.provider,
    m.scope
  from public.contentflow_evidence_requirements er
  left join public.contentflow_evidence_capability_matrix m
    on m.requirement_id = er.id
   and m.project_key = er.project_key
  where er.project_key = p_project_key
    and er.status = 'task_created'
  order by priority_score desc, er.id asc;
$$;

revoke all on function public.contentflow_evidence_coverage_plan(text) from public, anon, authenticated;
grant execute on function public.contentflow_evidence_coverage_plan(text) to service_role, postgres;
