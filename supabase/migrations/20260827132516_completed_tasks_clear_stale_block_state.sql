-- CONTENTFLOW_CHANGE_PROVENANCE_V1
-- change-class: recovery
-- lineage-recovered-from-production: true
-- original-statements-sha256: 7593943b130d8bac32b2a93d77598278e2fd7b64c07ce780cd7573fdc23a1d95

create or replace function public.contentflow_guard_backlog_completion()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare need_runtime boolean;
begin
 need_runtime:=public.contentflow_contract_runtime_required(new.workflow_contract,new.task_type,new.title,new.description,new.acceptance_criteria);
 if new.status='completed' and need_runtime and not coalesce(new.runtime_verified,false) then
   new.status:='verification_required';
   new.workflow_state:='runtime_verification_wait';
   new.completion_phase:='verification_required';
   new.blocked_reason:=null;
   new.updated_at:=now();
 elsif new.status='completed' then
   new.workflow_state:='completed';
   new.completion_phase:=case when coalesce(new.runtime_verified,false) then 'runtime_proven' else 'artifact_approved' end;
   new.patch_feedback:=null;
   new.blocked_reason:=null;
   new.next_eligible_at:=null;
   new.updated_at:=now();
 end if;
 return new;
end
$$;

update public.contentflow_build_backlog
set blocked_reason=null,next_eligible_at=null,updated_at=now()
where status='completed' and (blocked_reason is not null or next_eligible_at is not null);
