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
  circuit_open boolean := false;
begin
  durable := coalesce(new.workflow_contract->>'contract_version','') <> '';
  evidence_external := new.execution_lane='evidence_producer' and coalesce(new.workflow_contract->>'runtime_required','false')='true';
  explicit_external := coalesce(new.blocked_reason,'') like 'EXTERNAL_%' or coalesce(new.blocked_reason,'') like 'INFRASTRUCTURE_RUNTIME_EVIDENCE_REQUIRED';
  no_retry_without_evidence := coalesce(new.workflow_contract->>'no_retry_without_new_evidence','false')='true';
  internal_artifact := coalesce(new.execution_lane,'llm_artifact')='llm_artifact'
    and coalesce(new.workflow_contract->>'runtime_required','false')='false'
    and coalesce(new.workflow_contract->>'publish_allowed','false')<>'true';
  select exists(
    select 1 from public.contentflow_retry_state rs
    where rs.project_key=new.project_key and rs.task_key=new.task_key and rs.circuit_state='open'
  ) into circuit_open;

  if new.status='ready' then
    if exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=new.id and r.status='review_required' and r.finished_at is null) then
      new.status := 'blocked';
      new.blocked_reason := 'REVIEW_PENDING';
      new.next_eligible_at := null;
    elsif circuit_open then
      new.status := 'blocked';
      new.blocked_reason := 'RETRY_CIRCUIT_OPEN';
      new.next_eligible_at := null;
    else
      new.blocked_reason := null;
      new.next_eligible_at := coalesce(new.next_eligible_at,now());
    end if;
  elsif new.status='blocked' then
    if coalesce(new.blocked_reason,'')='REVIEW_PENDING'
       or exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=new.id and r.status='review_required' and r.finished_at is null) then
      new.blocked_reason := 'REVIEW_PENDING';
      new.next_eligible_at := null;
    elsif circuit_open then
      new.blocked_reason := 'RETRY_CIRCUIT_OPEN';
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

create or replace function public.rara_safe_requeue_failed_task(p_task_key text)
returns boolean
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_id bigint;
begin
  if p_task_key like 'gap_gap_%' then return false; end if;

  select b.id into v_id
  from public.contentflow_build_backlog b
  where b.project_key='contentflow' and b.task_key=p_task_key
    and b.status in ('failed','blocked')
    and exists(
      select 1 from public.contentflow_builder_runs lr
      where lr.backlog_task_id=b.id
        and lr.id=(select max(id) from public.contentflow_builder_runs z where z.backlog_task_id=b.id)
        and lr.status='failed'
    )
    and not exists(
      select 1 from public.contentflow_builder_runs r
      where r.backlog_task_id=b.id
        and r.status in ('claimed','running','review_required','verification_required')
        and r.finished_at is null
    )
  for update;

  if v_id is null then return false; end if;

  update public.contentflow_retry_state s
     set circuit_state='closed', circuit_open_until=null, next_retry_at=now(), updated_at=now()
   where s.backlog_task_id=v_id;

  update public.contentflow_build_backlog b
  set status='ready',
      selected_model=null,
      quality_score=0,
      blocked_reason=null,
      next_eligible_at=now(),
      updated_at=now(),
      result=coalesce(result,'')||E'\n[RARA] safe requeue after diagnosed failure/timeout'
  where b.id=v_id;

  return true;
end
$function$;

update public.contentflow_build_backlog b
set status='blocked', blocked_reason='RETRY_CIRCUIT_OPEN', next_eligible_at=null, selected_model=null, updated_at=now()
where b.project_key='contentflow'
  and b.status='ready'
  and exists (
    select 1 from public.contentflow_retry_state rs
    where rs.backlog_task_id=b.id and rs.circuit_state='open'
  );
