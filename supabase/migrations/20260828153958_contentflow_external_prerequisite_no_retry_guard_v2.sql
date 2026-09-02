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
begin
  durable := coalesce(new.workflow_contract->>'contract_version','') <> '';
  evidence_external := new.execution_lane='evidence_producer' and coalesce(new.workflow_contract->>'runtime_required','false')='true';
  explicit_external := coalesce(new.blocked_reason,'') like 'EXTERNAL_%' or coalesce(new.blocked_reason,'') like 'INFRASTRUCTURE_RUNTIME_EVIDENCE_REQUIRED';
  no_retry_without_evidence := coalesce(new.workflow_contract->>'no_retry_without_new_evidence','false')='true';

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
