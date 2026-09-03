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
  explicit_human boolean := false;
  explicit_evidence_gap boolean := false;
  no_retry_without_evidence boolean := false;
  internal_artifact boolean := false;
  circuit_open boolean := false;
begin
  durable := coalesce(new.workflow_contract->>'contract_version','') <> '';
  evidence_external := new.execution_lane='evidence_producer' and coalesce(new.workflow_contract->>'runtime_required','false')='true';
  explicit_external := coalesce(new.blocked_reason,'') like 'EXTERNAL_%' or coalesce(new.blocked_reason,'') like 'INFRASTRUCTURE_RUNTIME_EVIDENCE_REQUIRED';
  explicit_human := coalesce(new.blocked_reason,'') like 'HUMAN_%';
  explicit_evidence_gap := coalesce(new.blocked_reason,'') in ('VERIFIED_SOURCE_EVIDENCE_REQUIRED','AUTHENTIC_MEDIA_CAPTURE_REQUIRED','MEDIA_CAPTURE_CAPABILITY_UNAVAILABLE');
  no_retry_without_evidence := coalesce(new.workflow_contract->>'no_retry_without_new_evidence','false')='true';
  internal_artifact := coalesce(new.execution_lane,'llm_artifact')='llm_artifact' and coalesce(new.workflow_contract->>'runtime_required','false')='false' and coalesce(new.workflow_contract->>'publish_allowed','false')<>'true';
  select exists(select 1 from public.contentflow_retry_state rs where rs.project_key=new.project_key and rs.task_key=new.task_key and rs.circuit_state='open') into circuit_open;

  if new.status='ready' then
    if exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=new.id and r.status='review_required' and r.finished_at is null) then
      new.status:='blocked'; new.blocked_reason:='REVIEW_PENDING'; new.next_eligible_at:=null;
    elsif circuit_open then
      new.status:='blocked'; new.blocked_reason:='RETRY_CIRCUIT_OPEN'; new.next_eligible_at:=null;
    elsif explicit_human then
      new.status:='blocked'; new.next_eligible_at:=null;
    elsif coalesce(new.completion_phase,'')='evidence_required' then
      new.status:='blocked'; new.blocked_reason:=coalesce(nullif(new.blocked_reason,''),'VERIFIED_SOURCE_EVIDENCE_REQUIRED'); new.next_eligible_at:=null;
    else
      new.blocked_reason:=null; new.next_eligible_at:=coalesce(new.next_eligible_at,now());
    end if;
  elsif new.status='blocked' then
    if coalesce(new.blocked_reason,'')='REVIEW_PENDING' or exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=new.id and r.status='review_required' and r.finished_at is null) then
      new.blocked_reason:='REVIEW_PENDING'; new.next_eligible_at:=null;
    elsif circuit_open then
      new.blocked_reason:='RETRY_CIRCUIT_OPEN'; new.next_eligible_at:=null;
    elsif explicit_human then
      new.next_eligible_at:=null;
    elsif explicit_evidence_gap or coalesce(new.completion_phase,'')='evidence_required' then
      new.blocked_reason:=coalesce(nullif(new.blocked_reason,''),'VERIFIED_SOURCE_EVIDENCE_REQUIRED'); new.next_eligible_at:=null;
    elsif evidence_external or explicit_external or no_retry_without_evidence then
      if coalesce(new.blocked_reason,'')='' then new.blocked_reason:=case when new.task_key ilike '%social%access%' then 'EXTERNAL_PREREQUISITE_SOCIAL_ACCESS' when new.task_key ilike '%gpu%workspace%' then 'INFRASTRUCTURE_RUNTIME_EVIDENCE_REQUIRED' else 'EXTERNAL_RUNTIME_EVIDENCE_REQUIRED' end; end if;
      new.next_eligible_at:=null;
    elsif internal_artifact then
      new.status:='ready'; new.blocked_reason:=null; new.workflow_state:=coalesce(nullif(new.workflow_state,''),'artifact_pending'); new.next_eligible_at:=coalesce(new.next_eligible_at,now()+interval '5 seconds');
      new.patch_feedback:=concat_ws(E'\n',nullif(new.patch_feedback,''),'AUTO_CLASSIFIED_INTERNAL_ARTIFACT_V2: generic block converted to READY; runtime/publication evidence not required.');
    elsif durable and new.workflow_state in ('patch_required','artifact_patch_required','retry_wait') then
      new.status:='ready'; new.blocked_reason:=null; new.next_eligible_at:=coalesce(new.next_eligible_at,now()+interval '15 seconds');
    else
      new.blocked_reason:=coalesce(nullif(new.blocked_reason,''),'STATE_GUARD_BLOCKED_UNSPECIFIED'); new.next_eligible_at:=coalesce(new.next_eligible_at,now()+interval '7 minutes');
    end if;
  end if;
  return new;
end $function$;
