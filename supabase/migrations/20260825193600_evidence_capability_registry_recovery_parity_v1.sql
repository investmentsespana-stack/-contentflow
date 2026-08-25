-- Reconstructed from live production catalog on 2026-08-25.
create table if not exists public.contentflow_evidence_capability_registry(
  prerequisite text primary key,
  verifier_available boolean not null default false,
  producer_available boolean not null default false,
  provider text,
  scope text,
  updated_at timestamptz not null default now()
);

create or replace function public.contentflow_evidence_prerequisite_class(p_requirement_class text,p_requirement_text text)
returns text language sql immutable set search_path to 'public','pg_temp' as $function$
 select case
   when coalesce(p_requirement_class,'')='external_approval' or lower(coalesce(p_requirement_text,'')) ~ '(requires? (manual|human) approval|pending owner decision|(human|owner|security team|architecture team)[ -]?(approval|sign.?off|authorization))' then 'external_approval'
   when (lower(coalesce(p_requirement_text,'')) ~ '(commit hash|commit sha|repository|repo link|file path|merged into|published|version-controlled|version control)' and lower(coalesce(p_requirement_text,'')) ~ '(unit test|integration test|test suite|test corpus|test execution|coverage|executed|execution on|runtime report|runtime evidence|30 positive test|test cases|machine-readable report)') then 'repo_and_runtime_test'
   when coalesce(p_requirement_class,'')='static_analysis' then 'static_analysis'
   when coalesce(p_requirement_class,'')='runtime_test' then 'runtime_test'
   when coalesce(p_requirement_class,'')='source_contract' then 'source_contract'
   when coalesce(p_requirement_class,'') in ('runtime_evidence','persistence_integration') then 'runtime_persistence'
   when lower(coalesce(p_requirement_text,'')) ~ '(commit hash|commit sha|repository|repo link|file path|merged into|published|version-controlled|version control)' then 'repo_commit_or_file'
   when lower(coalesce(p_requirement_text,'')) ~ '(static analysis|lint|mypy|scanner|scan)' then 'static_analysis'
   when lower(coalesce(p_requirement_text,'')) ~ '(platformstore|record_evidence|evidence store|durable storage|database record|database query|persisted runtime|runtime evidence|runtime log|runtime trace)' then 'runtime_persistence'
   when lower(coalesce(p_requirement_text,'')) ~ '(unit test|integration test|test suite|test corpus|test execution|coverage|benchmark|http 400|http 200)' then 'runtime_test'
   when lower(coalesce(p_requirement_text,'')) ~ '(interface|contract|schema|missing method|field)' then 'source_contract'
   when lower(coalesce(p_requirement_text,'')) ~ '(deploy|deployment|staging|production)' then 'deployment_trace'
   else 'other'
 end;
$function$;

create or replace function public.contentflow_tool_execution_capability_ready(p_project_key text,p_task_key text)
returns boolean language plpgsql stable security definer set search_path to 'public' as $function$
declare b record; er record; prereq text; producer boolean:=false;
begin
 select id,epic,completion_phase into b from public.contentflow_build_backlog where project_key=p_project_key and task_key=p_task_key order by id desc limit 1;
 if not found then return false; end if;
 if coalesce(b.epic,'')<>'evidence_first' and coalesce(b.completion_phase,'')<>'evidence_required' then return true; end if;
 select * into er from public.contentflow_evidence_requirements where project_key=p_project_key and evidence_task_key=p_task_key order by id desc limit 1;
 if not found then return false; end if;
 if public.contentflow_evidence_verifier_preflight(p_project_key,p_task_key) then return true; end if;
 prereq:=public.contentflow_evidence_prerequisite_class(er.requirement_class,er.requirement_text);
 select coalesce(producer_available,false) into producer from public.contentflow_evidence_capability_registry where prerequisite=prereq;
 return coalesce(producer,false);
end;
$function$;

insert into public.contentflow_evidence_capability_registry(prerequisite,verifier_available,producer_available,provider,scope) values
('deployment_trace',false,false,null,'no deterministic deployment trace producer/verifier registered'),
('external_approval',true,false,'contentflow-evidence-tool-runner','verify persisted approval evidence only'),
('other',false,false,null,'unclassified prerequisite; must be classified before execution'),
('repo_and_runtime_test',false,false,null,'composite gate: requires both repository evidence and executed test/runtime evidence; never satisfied by file existence alone'),
('repo_commit_or_file',true,true,'contentflow-evidence-tool-runner:v5','verify real public GitHub repository files on main and persist path/blob SHA/URL; no fabricated repository evidence'),
('runtime_persistence',true,true,'contentflow-capability-e2e-certifier','certified bounded producer; activation requires persisted E2E verification plus RARA-approved run'),
('runtime_test',true,true,'contentflow-capability-e2e-certifier','certified bounded producer; activation requires persisted E2E verification plus RARA-approved run'),
('source_contract',true,true,'contentflow-capability-e2e-certifier','certified bounded producer; activation requires persisted E2E verification plus RARA-approved run'),
('static_analysis',true,false,'contentflow-evidence-tool-runner','verify persisted static/lint/mypy/scan evidence')
on conflict(prerequisite) do update set verifier_available=excluded.verifier_available,producer_available=excluded.producer_available,provider=excluded.provider,scope=excluded.scope,updated_at=now();

revoke all on table public.contentflow_evidence_capability_registry from anon,authenticated;
grant select,insert,update,delete on table public.contentflow_evidence_capability_registry to service_role;
revoke all on function public.contentflow_tool_execution_capability_ready(text,text) from public,anon,authenticated;
grant execute on function public.contentflow_tool_execution_capability_ready(text,text) to service_role;
