-- CONTENTFLOW_CHANGE_PROVENANCE_V1
-- change-class: recovery
-- lineage-recovered-from-production: true
-- original-statements-sha256: a483954453a9356f3f567b266444e3a5ee31e80cd47beae2b177b143754f61f9

insert into public.contentflow_retry_policies(error_class,retryable,max_attempts,initial_backoff_seconds,backoff_coefficient,max_backoff_seconds,jitter_ratio,switch_model_on_retry)
values ('artifact_defect',true,3,15,2,90,0.15,true)
on conflict(error_class) do update set retryable=true,max_attempts=3,initial_backoff_seconds=15,backoff_coefficient=2,max_backoff_seconds=90,jitter_ratio=0.15,switch_model_on_retry=true;

create or replace function public.contentflow_classify_run_error(p_error text)
returns text
language sql
immutable
set search_path to 'public','pg_temp'
as $function$
 select case
   when coalesce(p_error,'') ilike '%artifact_truncated%' or coalesce(p_error,'') ilike '%TRUNCATED_RESPONSE%' then 'artifact_truncation'
   when coalesce(p_error,'') ilike '%ARTIFACT_DEFECT%' or coalesce(p_error,'') ilike '%syntax error%' or coalesce(p_error,'') ilike '%prevents compilation%' then 'artifact_defect'
   when coalesce(p_error,'') ilike '%EXTERNAL_APPROVAL_WAIT%' then 'acceptance_evidence'
   when coalesce(p_error,'') ilike '%nexo_lane_capacity_limited%' or coalesce(p_error,'') ilike '%capacity%' or coalesce(p_error,'') ilike '%429%' or coalesce(p_error,'') ilike '%rate_limit%' then 'capacity'
   when coalesce(p_error,'') ilike '%judge_unavailable%' or coalesce(p_error,'') ilike '%judge_unavailable_or_unparseable%' then 'judge'
   when coalesce(p_error,'') ilike '%worker_transport_failed%' or coalesce(p_error,'') ilike '%transport_failed%' or coalesce(p_error,'') ilike '%worker_provider_failed%' or coalesce(p_error,'') ilike '%provider_failed%' or coalesce(p_error,'') ilike '%runner_response_parse_failed%' or coalesce(p_error,'') ilike '%runner_response_parse%' or coalesce(p_error,'') ilike '%execution_failed%' then 'provider'
   when coalesce(p_error,'') ilike '%timeout%' or coalesce(p_error,'') ilike '%120000 ms%' then 'timeout'
   when coalesce(p_error,'') ilike '%ORPHAN_CLAIM%' or coalesce(p_error,'') ilike '%lease_expired%' or coalesce(p_error,'') ilike '%LEASE_REVOKED%' or coalesce(p_error,'') ilike '%stale_claim%' or coalesce(p_error,'') ilike '%worker_claim_race%' or coalesce(p_error,'') ilike '%fenced_out%' then 'state_recovery'
   when coalesce(p_error,'') ilike '%RARA_ARTIFACT_REVIEW_REJECTED%' or coalesce(p_error,'') ilike '%RARA_REVIEW_REJECTED%' then 'quality_review'
   when coalesce(p_error,'') ilike '%quality_or_cost_gate_failed%' then 'quality_gate'
   when coalesce(p_error,'') ilike '%REVIEW_REJECTED_AUTONOMOUS_SLA%' or coalesce(p_error,'') ilike '%Evidence not correlated%' or coalesce(p_error,'') ilike '%evidence missing%' or coalesce(p_error,'') ilike '%missing platform evidence%' or coalesce(p_error,'') ilike '%acceptance criterion%' then 'acceptance_evidence'
   else 'unknown' end;
$function$;
