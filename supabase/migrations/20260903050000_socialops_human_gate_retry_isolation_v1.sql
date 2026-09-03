-- Social Ops / Cygnus: human approval gates are durable external waits, not retry failures.

create or replace function public.contentflow_classify_run_error(p_error text)
returns text
language sql
immutable
set search_path to 'public','pg_temp'
as $function$
 select case
   when coalesce(p_error,'') ilike '%voice not final%'
     or coalesce(p_error,'') ilike '%voice_final=false%'
     or coalesce(p_error,'') ilike '%publication_authorized=false%'
     or coalesce(p_error,'') ilike '%final cygnus voice%approval%'
     or coalesce(p_error,'') ilike '%human_final_%'
     or coalesce(p_error,'') ilike '%owner approval%'
     or coalesce(p_error,'') ilike '%human approval%'
     then 'human_external_gate'
   when coalesce(p_error,'') ilike '%artifact_truncated%' or coalesce(p_error,'') ilike '%TRUNCATED_RESPONSE%' then 'artifact_truncation'
   when coalesce(p_error,'') ilike '%ARTIFACT_DEFECT%' or coalesce(p_error,'') ilike '%syntax error%' or coalesce(p_error,'') ilike '%prevents compilation%' then 'artifact_defect'
   when coalesce(p_error,'') ilike '%EXTERNAL_APPROVAL_WAIT%' then 'human_external_gate'
   when coalesce(p_error,'') ilike '%nexo_lane_capacity_limited%' or coalesce(p_error,'') ilike '%capacity%' or coalesce(p_error,'') ilike '%429%' or coalesce(p_error,'') ilike '%rate_limit%' then 'capacity'
   when coalesce(p_error,'') ilike '%judge_unavailable%' or coalesce(p_error,'') ilike '%judge_unavailable_or_unparseable%' then 'judge'
   when coalesce(p_error,'') ilike '%no_catalog_model_executable%' or coalesce(p_error,'') ilike '%worker_transport_failed%' or coalesce(p_error,'') ilike '%transport_failed%' or coalesce(p_error,'') ilike '%worker_provider_failed%' or coalesce(p_error,'') ilike '%provider_failed%' or coalesce(p_error,'') ilike '%runner_response_parse_failed%' or coalesce(p_error,'') ilike '%runner_response_parse%' or coalesce(p_error,'') ilike '%execution_failed%' then 'provider'
   when coalesce(p_error,'') ilike '%timeout%' or coalesce(p_error,'') ilike '%120000 ms%' then 'timeout'
   when coalesce(p_error,'') ilike '%ORPHAN_CLAIM%' or coalesce(p_error,'') ilike '%lease_expired%' or coalesce(p_error,'') ilike '%LEASE_REVOKED%' or coalesce(p_error,'') ilike '%stale_claim%' or coalesce(p_error,'') ilike '%worker_claim_race%' or coalesce(p_error,'') ilike '%fenced_out%' then 'state_recovery'
   when coalesce(p_error,'') ilike '%RARA_ARTIFACT_REVIEW_REJECTED%' or coalesce(p_error,'') ilike '%RARA_REVIEW_REJECTED%' then 'quality_review'
   when coalesce(p_error,'') ilike '%quality_or_cost_gate_failed%' then 'quality_gate'
   when coalesce(p_error,'') ilike '%REVIEW_REJECTED_AUTONOMOUS_SLA%' or coalesce(p_error,'') ilike '%Evidence not correlated%' or coalesce(p_error,'') ilike '%evidence missing%' or coalesce(p_error,'') ilike '%missing platform evidence%' or coalesce(p_error,'') ilike '%acceptance criterion%' then 'acceptance_evidence'
   else 'unknown' end;
$function$;

create or replace function public.rara_classify_rejection(p_reason text)
returns text
language sql
immutable
set search_path to 'public'
as $function$
with x as (select lower(coalesce(p_reason,'')) s)
select case
  when s like '%voice not final%' or s like '%voice_final=false%' or s like '%publication_authorized=false%' or s like '%final cygnus voice%' or s like '%human approval%' or s like '%owner approval%' or s like '%legal%' or s like '%counsel%' or s like '%consent%' or s like '%biometric%' or s like '%privacy%' or s like '%purchase%' or s like '%cost authorization%' or s like '%gpu rental%' or s like '%production deploy%' or s like '%irreversible%' then 'owner_required'
  when s like '%vendor claim%' or s like '%benchmark result%' or s like '%independent verification%' or s like '%unverified hardware%' or s like '%unverified latency%' or s like '%route a%' or s like '%route b%' or s like '%route c%' or s like '%mapping%a/b/c%' then 'vendor_claim_not_benchmark'
  when (s like '%hardcod%' and (s like '%builder%' or s like '%execution%' or s like '%correlation%' or s like '%run id%' or s like '%run_id%')) or s like '%builder_run_id%' or s like '%run-specific%' then 'hardcoded_execution_identity'
  when s like '%placeholder%' or s like '%stub%' or s like '%scaffold%' or s like '%empty json%' or s like '%empty object%' then 'placeholder_or_stub'
  when s like '%missing evidence%' or s like '%evidence%insufficient%' or s like '%runtime proof%' or s like '%persisted evidence%' or s like '%acceptance criterion%' or s like '%verification%' then 'acceptance_evidence'
  when s like '%contract%' or s like '%interface%' or s like '%integration%not%verified%' or s like '%incomplete%' then 'contract_incomplete'
  else 'correctable_quality'
end from x
$function$;

create or replace function public.contentflow_apply_retry_policy(p_run_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
 r public.contentflow_builder_runs%rowtype;
 b public.contentflow_build_backlog%rowtype;
 p public.contentflow_retry_policies%rowtype;
 s public.contentflow_retry_state%rowtype;
 cls text; att int; base_delay numeric; jitter numeric; delay_s int; next_at timestamptz;
 deps_complete boolean:=true;
 target_status text;
 late_judge_pass boolean:=false;
 late_runner_pass boolean:=false;
begin
 select * into r from public.contentflow_builder_runs where id=p_run_id;
 if not found or r.status not in ('failed','deferred') then return jsonb_build_object('applied',false,'reason','run_not_failed'); end if;
 select * into b from public.contentflow_build_backlog where id=r.backlog_task_id for update;
 if not found then return jsonb_build_object('applied',false,'reason','backlog_missing'); end if;

 cls:=public.contentflow_classify_run_error(r.error);

 if cls='human_external_gate' then
   delete from public.contentflow_retry_state where backlog_task_id=b.id;
   update public.contentflow_build_backlog
      set status='blocked',
          blocked_reason=case when coalesce(r.error,'') ilike '%voice%' then 'HUMAN_FINAL_CYGNUS_VOICE_APPROVAL_REQUIRED' else 'HUMAN_EXTERNAL_APPROVAL_REQUIRED' end,
          selected_model=null,next_eligible_at=null,workflow_state='external_approval_wait',completion_phase='external_prerequisite',updated_at=now()
    where id=b.id;
   insert into public.contentflow_runtime_event_ledger(project_key,builder_run_id,task_key,event_type,idempotency_key,actor,payload,trace_id)
   values(b.project_key,r.id,b.task_key,'human_gate_isolated_from_retry',r.idempotency_key,'director_retry_policy',
     jsonb_build_object('error_class',cls,'blocked_reason',case when coalesce(r.error,'') ilike '%voice%' then 'HUMAN_FINAL_CYGNUS_VOICE_APPROVAL_REQUIRED' else 'HUMAN_EXTERNAL_APPROVAL_REQUIRED' end,'retry_suppressed',true),r.trace_id)
   on conflict do nothing;
   return jsonb_build_object('applied',true,'action','human_gate_wait','class',cls,'task_key',b.task_key);
 end if;

 if coalesce(r.error,'') ilike '%quality_or_cost_gate_failed%' then
   select coalesce(bool_or((payload->>'pass')::boolean) filter(where event_type='judge_completed'),false),
          coalesce(bool_or((payload->>'pass')::boolean) filter(where event_type='runner_completed'),false)
   into late_judge_pass,late_runner_pass
   from public.contentflow_runtime_event_ledger where builder_run_id=r.id;
   if late_judge_pass and late_runner_pass then
     delete from public.contentflow_retry_state where backlog_task_id=b.id;
     update public.contentflow_build_backlog
        set status=case when not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(dep) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.dep and x.status='completed')) then 'ready' else 'planned' end,
            selected_model=null,blocked_reason=null,
            next_eligible_at=case when not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d2(dep) where not exists(select 1 from public.contentflow_build_backlog x2 where x2.project_key=b.project_key and x2.task_key=d2.dep and x2.status='completed')) then now() else next_eligible_at end,
            updated_at=now()
      where id=b.id and status<>'completed';
     insert into public.contentflow_runtime_event_ledger(project_key,builder_run_id,task_key,event_type,idempotency_key,actor,payload,trace_id)
     values(b.project_key,r.id,b.task_key,'false_quality_failure_tombstoned',r.idempotency_key,'director_retry_policy',jsonb_build_object('reason','async_ack_race','judge_pass',late_judge_pass,'runner_pass',late_runner_pass),r.trace_id)
     on conflict do nothing;
     return jsonb_build_object('applied',true,'action','false_quality_failure_tombstoned','run_id',r.id,'task_key',b.task_key);
   end if;
 end if;

 select * into p from public.contentflow_retry_policies where error_class=cls;
 if not found then select * into p from public.contentflow_retry_policies where error_class='unknown'; end if;
 select * into s from public.contentflow_retry_state where backlog_task_id=b.id for update;
 if found and s.last_run_id=r.id then return jsonb_build_object('applied',false,'reason','already_processed','class',cls,'attempt',s.attempt_count); end if;
 att:=case when found and s.error_class=cls then s.attempt_count+1 else 1 end;
 select not exists(select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value) where not exists(select 1 from public.contentflow_build_backlog d where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed')) into deps_complete;

 if p.retryable and att<=p.max_attempts then
   base_delay:=least(p.max_backoff_seconds::numeric,p.initial_backoff_seconds*power(p.backoff_coefficient,att-1));
   jitter:=((('x'||substr(md5(b.task_key||':'||r.id::text),1,8))::bit(32)::bigint % 10001)::numeric/10000.0*2-1)*p.jitter_ratio;
   delay_s:=greatest(1,round(base_delay*(1+jitter))::int);
   next_at:=now()+make_interval(secs=>delay_s);
   target_status:=case when deps_complete then 'ready' else 'planned' end;
   insert into public.contentflow_retry_state(backlog_task_id,project_key,task_key,error_class,attempt_count,last_run_id,last_error,last_model,next_retry_at,circuit_state,circuit_open_until,updated_at)
   values(b.id,b.project_key,b.task_key,cls,att,r.id,r.error,r.selected_model,next_at,'cooldown',next_at,now())
   on conflict(backlog_task_id) do update set error_class=excluded.error_class,attempt_count=excluded.attempt_count,last_run_id=excluded.last_run_id,last_error=excluded.last_error,last_model=excluded.last_model,next_retry_at=excluded.next_retry_at,circuit_state='cooldown',circuit_open_until=excluded.circuit_open_until,updated_at=now();
   update public.contentflow_build_backlog set status=target_status,selected_model=null,next_eligible_at=next_at,updated_at=now() where id=b.id and status in ('failed','blocked','ready','planned');
   insert into public.contentflow_runtime_event_ledger(project_key,builder_run_id,task_key,event_type,idempotency_key,actor,payload,trace_id)
   values(b.project_key,r.id,b.task_key,'retry_scheduled',r.idempotency_key,'director_retry_policy',jsonb_build_object('error_class',cls,'attempt',att,'delay_seconds',delay_s,'next_retry_at',next_at,'switch_model',p.switch_model_on_retry,'dependencies_complete',deps_complete,'target_status',target_status),r.trace_id) on conflict do nothing;
   return jsonb_build_object('applied',true,'action','retry_scheduled','class',cls,'attempt',att,'next_retry_at',next_at,'delay_seconds',delay_s,'dependencies_complete',deps_complete,'target_status',target_status);
 else
   insert into public.contentflow_retry_state(backlog_task_id,project_key,task_key,error_class,attempt_count,last_run_id,last_error,last_model,next_retry_at,circuit_state,circuit_open_until,updated_at)
   values(b.id,b.project_key,b.task_key,cls,att,r.id,r.error,r.selected_model,null,'open',null,now())
   on conflict(backlog_task_id) do update set error_class=excluded.error_class,attempt_count=excluded.attempt_count,last_run_id=excluded.last_run_id,last_error=excluded.last_error,last_model=excluded.last_model,next_retry_at=null,circuit_state='open',circuit_open_until=null,updated_at=now();
   update public.contentflow_build_backlog set status='blocked',selected_model=null,next_eligible_at=null,updated_at=now() where id=b.id and status in ('failed','ready','planned','blocked');
   insert into public.contentflow_runtime_event_ledger(project_key,builder_run_id,task_key,event_type,idempotency_key,actor,payload,trace_id)
   values(b.project_key,r.id,b.task_key,'retry_blocked',r.idempotency_key,'director_retry_policy',jsonb_build_object('error_class',cls,'attempt',att,'retryable',p.retryable,'max_attempts',p.max_attempts),r.trace_id) on conflict do nothing;
   return jsonb_build_object('applied',true,'action','blocked_for_repair','class',cls,'attempt',att);
 end if;
end
$function$;

-- Repair the existing misclassified F06/F09 final-QA wait without rerender or redispatch.
delete from public.contentflow_retry_state rs
using public.contentflow_build_backlog b
where rs.backlog_task_id=b.id
  and b.project_key='agent-academy-platform-v1'
  and b.task_key='academy_social_rara_final_f06_f09_v3'
  and rs.circuit_state='open'
  and public.contentflow_classify_run_error(rs.last_error)='human_external_gate';

update public.contentflow_build_backlog
set status='blocked',blocked_reason='HUMAN_FINAL_CYGNUS_VOICE_APPROVAL_REQUIRED',selected_model=null,next_eligible_at=null,
    workflow_state='external_approval_wait',completion_phase='external_prerequisite',updated_at=now()
where project_key='agent-academy-platform-v1'
  and task_key='academy_social_rara_final_f06_f09_v3'
  and status='blocked';