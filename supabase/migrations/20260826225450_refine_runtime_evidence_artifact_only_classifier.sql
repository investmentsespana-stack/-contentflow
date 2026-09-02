-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_requires_runtime_evidence(p_task_type text, p_title text, p_description text, p_acceptance_criteria text)
returns boolean
language sql
immutable
set search_path to 'public'
as $function$
with s as (
  select lower(coalesce(p_title,'')||' '||coalesce(p_description,'')||' '||coalesce(p_acceptance_criteria,'')) as txt,
         lower(coalesce(p_task_type,'')) as task_type
), f as (
  select *,
    txt ~ '(must .*runtime|runtime verification required|verified by .*runtime|live execution required|actual execution required|deploy(ed|ment)? required|integration test required|runtime test required|runtime evidence required|executed in .*sandbox|runtime canary|sandbox deploy)' as explicit_runtime,
    txt ~ '(blueprint|strategy|warm[- ]up|plan\b|document(ed|ation)?|define\b|specif(y|ication)|architecture blueprint|information architecture|no production deployment claim|external service boundary)' as design_only,
    txt ~ '(implementation[- ]ready .*artifact|instrumentation spec|do not claim live telemetry|not a confirmation of (its )?deployment|no production deployment claim|source artifact .*does not claim deployment)' as artifact_only
  from s
)
select case
  when txt ~ '(official primary sources|source-only|source only|claim-to-source|evidence gaps|pending_benchmark|pending evidence)'
       and not explicit_runtime then false
  when explicit_runtime then true
  when artifact_only then false
  when task_type='code' then true
  when design_only then false
  when task_type='architecture' then
    txt ~ '(runtime|deploy|deployment|integration|endpoint|database|sql|migration|rollback|restore|trigger|rls|secret|vault|cron|worker|lease|claim|idempot|api)'
  else
    txt ~ '(runtime|deploy|deployment|integration|endpoint|database|sql|migration|rollback|restore|trigger|rls|secret|vault|cron|worker|lease|claim|idempot|api)'
end from f;
$function$;
