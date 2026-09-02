-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_backlog_state_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  durable boolean := false;
  evidence_external boolean := false;
  explicit_external boolean := false;
  no_retry_without_evidence boolean := false;
  internal_artifact boolean := false;
begin
  durable := coalesce(new.workflow_contract->>'contract_version','') <> '';
  evidence_external := new.execution_lane='evidence_producer' and coalesce(new.workflow_contract->>'runtime_required','false')='true';
  explicit_external := coalesce(new.blocked_reason,'') like 'EXTERNAL_%' or coalesce(new.blocked_reason,'') like 'INFRASTRUCTURE_RUNTIME_EVIDENCE_REQUIRED';
  no_retry_without_evidence := coalesce(new.workflow_contract->>'no_retry_without_new_evidence','false')='true';
  internal_artifact := coalesce(new.execution_lane,'llm_artifact')='llm_artifact'
    and coalesce(new.workflow_contract->>'runtime_required','false')='false'
    and coalesce(new.workflow_contract->>'publish_allowed','false')<>'true';

  if new.status='ready' then
    if exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=new.id and r.status='review_required') then
      new.status := 'blocked';
      new.blocked_reason := 'REVIEW_PENDING';
      new.next_eligible_at := null;
    else
      new.blocked_reason := null;
      new.next_eligible_at := coalesce(new.next_eligible_at,now());
      if not durable then
        update public.contentflow_retry_state
        set circuit_state='closed',circuit_open_until=null,next_retry_at=null,updated_at=now()
        where project_key=new.project_key and task_key=new.task_key and circuit_state='open';
      end if;
    end if;
  elsif new.status='blocked' then
    if coalesce(new.blocked_reason,'')='REVIEW_PENDING'
       or exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=new.id and r.status='review_required') then
      new.blocked_reason := 'REVIEW_PENDING';
      new.next_eligible_at := null;
    elsif evidence_external or explicit_external or no_retry_without_evidence then
      if coalesce(new.blocked_reason,'')='' then
        new.blocked_reason := case
          when new.task_key ilike '%social%access%' then 'EXTERNAL_PREREQUISITE_SOCIAL_ACCESS'
          when new.task_key ilike '%gpu%workspace%' then 'INFRASTRUCTURE_RUNTIME_EVIDENCE_REQUIRED'
          else 'EXTERNAL_RUNTIME_EVIDENCE_REQUIRED'
        end;
      end if;
      new.next_eligible_at := null;
    elsif internal_artifact then
      new.status := 'ready';
      new.blocked_reason := null;
      new.workflow_state := coalesce(nullif(new.workflow_state,''),'artifact_pending');
      new.next_eligible_at := coalesce(new.next_eligible_at,now()+interval '5 seconds');
      new.patch_feedback := concat_ws(E'\n',nullif(new.patch_feedback,''),'AUTO_CLASSIFIED_INTERNAL_ARTIFACT_V2: generic block converted to READY; runtime/publication evidence not required.');
    elsif durable and new.workflow_state in ('patch_required','artifact_patch_required','retry_wait') then
      new.status := 'ready';
      new.blocked_reason := null;
      new.next_eligible_at := coalesce(new.next_eligible_at,now()+interval '15 seconds');
    else
      new.blocked_reason := coalesce(nullif(new.blocked_reason,''),'STATE_GUARD_BLOCKED_UNSPECIFIED');
      new.next_eligible_at := coalesce(new.next_eligible_at,now()+interval '7 minutes');
    end if;
  end if;
  return new;
end
$function$;

update public.contentflow_build_backlog
set status='ready', blocked_reason=null, next_eligible_at=now(), workflow_state=coalesce(nullif(workflow_state,''),'artifact_pending'), updated_at=now(),
    patch_feedback=concat_ws(E'\n',nullif(patch_feedback,''),'REPAIR academy_state_guard_artifact_classification_v2: reopened safe llm_artifact task previously generic-blocked.')
where project_key='agent-academy-platform-v1'
  and status='blocked'
  and coalesce(blocked_reason,'')='STATE_GUARD_BLOCKED_UNSPECIFIED'
  and coalesce(execution_lane,'llm_artifact')='llm_artifact'
  and coalesce(workflow_contract->>'runtime_required','false')='false'
  and coalesce(workflow_contract->>'publish_allowed','false')<>'true';

insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes)
values('agent-academy-platform-v1','state_guard_learning','academy_state_guard_artifact_classification_v2','automatic_recovery','SAFE_LLM_ARTIFACT_GENERIC_BLOCK_CLASSIFIED_AND_REOPENED',false,'Director/RARA learning: llm_artifact tasks with runtime_required=false and no public-write authorization must not be parked as STATE_GUARD_BLOCKED_UNSPECIFIED; classify as internal artifact and return to READY unless review/external evidence/circuit policy explicitly blocks them.');
