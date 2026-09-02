-- Social Ops media-capture capability contract v1
-- Prevents generic deterministic evidence runners from pretending to produce authentic audiovisual evidence.

create or replace function public.contentflow_evidence_prerequisite_class(p_requirement_class text, p_requirement_text text)
returns text
language sql
immutable
set search_path to 'public','pg_temp'
as $function$
 select case
   when coalesce(p_requirement_class,'')='media_capture'
     or lower(coalesce(p_requirement_text,'')) ~ '(video|subtitle|keyframe|sha-256|sha256|screen recording|audiovisual|master premium|short variant|real screen|pantalla real)'
     then 'media_capture'
   when coalesce(p_requirement_class,'')='external_approval'
     or lower(coalesce(p_requirement_text,'')) ~ '(requires? (manual|human) approval|pending owner decision|(human|owner|security team|architecture team)[ -]?(approval|sign.?off|authorization))'
     then 'external_approval'
   when (
     lower(coalesce(p_requirement_text,'')) ~ '(commit hash|commit sha|repository|repo link|file path|merged into|published|version-controlled|version control)'
     and lower(coalesce(p_requirement_text,'')) ~ '(unit test|integration test|test suite|test corpus|test execution|coverage|executed|execution on|runtime report|runtime evidence|30 positive test|test cases|machine-readable report)'
   ) then 'repo_and_runtime_test'
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

insert into public.contentflow_evidence_capability_registry(prerequisite,verifier_available,producer_available,provider,scope,updated_at)
values('media_capture',false,false,null,'Authentic audiovisual/screen-capture producer required. Must create real master/short media, subtitles, keyframes, SHA-256 and QA provenance; generic LLM/database evidence producers are not sufficient.',now())
on conflict(prerequisite) do update set verifier_available=false,producer_available=false,provider=null,scope=excluded.scope,updated_at=now();

insert into public.contentflow_evidence_requirements(project_key,backlog_task_id,source_run_id,task_key,requirement_class,requirement_fingerprint,requirement_text,evidence_task_key,status,evidence_ref,updated_at)
select b.project_key,b.id,r.id,b.task_key,'media_capture',md5('socialops-media-v1:'||b.task_key),
       'Authentic media production required: real/source-grounded video or screen capture as specified, professional master/short where required, subtitles, keyframes, SHA-256 manifest, audiovisual QA, publication gate CLOSED.',
       b.task_key,'open','{}'::jsonb,now()
from public.contentflow_build_backlog b
join lateral (select br.id from public.contentflow_builder_runs br where br.backlog_task_id=b.id order by br.id desc limit 1) r on true
where b.project_key='contentflow' and b.task_key in ('socialops_today_warmup_f02_v1','socialops_today_warmup_f03_v1','socialops_today_warmup_f04_v1','socialops_today_warmup_f05_v1','socialops_today_warmup_f06_v1','socialops_today_warmup_f07_v1','socialops_today_warmup_f08_v1','socialops_today_warmup_f09_v1')
and not exists(select 1 from public.contentflow_evidence_requirements er where er.project_key=b.project_key and er.task_key=b.task_key and er.requirement_fingerprint=md5('socialops-media-v1:'||b.task_key));

update public.contentflow_build_backlog b
set status='blocked', blocked_reason='MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE', execution_lane='evidence_producer', updated_at=now()
where b.project_key='contentflow' and b.task_key in ('socialops_today_warmup_f02_v1','socialops_today_warmup_f03_v1','socialops_today_warmup_f04_v1','socialops_today_warmup_f05_v1','socialops_today_warmup_f06_v1','socialops_today_warmup_f07_v1','socialops_today_warmup_f08_v1','socialops_today_warmup_f09_v1')
and not exists (
  select 1 from public.director_external_evidence e
  where e.project_key=b.project_key and e.task_key=b.task_key and e.verified=true and e.status='pass'
    and (e.evidence ? 'sha256' or e.evidence ? 'manifest_sha256' or e.evidence ? 'artifact_sha256')
);

select public.contentflow_sync_tool_execution_queue('contentflow');
