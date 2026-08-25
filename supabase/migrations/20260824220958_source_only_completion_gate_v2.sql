-- Reconstructed from the live production catalog on 2026-08-25.
-- This file restores the effective SOURCE_ONLY completion contract that existed
-- in production but was missing from repository lineage.

create or replace function public.contentflow_requires_runtime_evidence(
  p_task_type text,
  p_title text,
  p_description text,
  p_acceptance_criteria text
) returns boolean
language sql
immutable
set search_path to 'public'
as $function$
with s as (
  select lower(coalesce(p_title,'')||' '||coalesce(p_description,'')||' '||coalesce(p_acceptance_criteria,'')) as txt,
         lower(coalesce(p_task_type,'')) as task_type
)
select case
  when txt ~ '(official primary sources|source-only|source only|claim-to-source|evidence gaps|pending_benchmark|pending evidence)'
       and txt !~ '(must .*runtime|runtime verification required|verified by .*runtime|live execution required|actual execution required|deploy(ed|ment)? required|integration test required|runtime test required|runtime evidence required)'
    then false
  when task_type='code' then true
  when task_type='architecture'
       and txt ~ '(source artifact|declarative|schema[_ ]only|architecture contract)'
       and txt !~ '(end[- ]to[- ]end|\be2e\b|must .*runtime|verified by .*runtime|live execution|actual execution|deploy(ed|ment)?|integration test|runtime test|runtime evidence)'
    then false
  when task_type='architecture' then
    txt ~ '(runtime|deploy|deployment|integration|endpoint|database|sql|migration|guardrail|rollback|boundary|enforce|blocking|block |restore|trigger|rls|secret|vault|cron|worker|lease|claim|idempot|api)'
  else
    txt ~ '(runtime|deploy|deployment|integration|endpoint|database|sql|migration|guardrail|rollback|boundary|enforce|blocking|block |restore|trigger|rls|secret|vault|cron|worker|lease|claim|idempot|api)'
end from s;
$function$;
