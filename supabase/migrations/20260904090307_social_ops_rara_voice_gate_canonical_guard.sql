-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_guard_social_ops_rara_voice_gate()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if new.task_key = 'academy_social_rara_final_f06_f09_v3'
     and new.status = 'blocked'
     and coalesce(new.patch_feedback,'') ilike '%VOICE_APPROVAL_RESOLVED%'
     and exists (
       select 1
       from public.contentflow_build_backlog d
       where d.project_key = new.project_key
         and d.task_key = 'academy_social_revoice_f06_f09_bella_v1'
         and not (d.status = 'completed' and coalesce(d.runtime_verified,false) = true)
     )
  then
    new.blocked_reason := 'BELLA_REVOICE_RUNTIME_EVIDENCE_REQUIRED';
    new.workflow_state := 'external_prerequisite';
    new.completion_phase := 'external_prerequisite';
    new.next_eligible_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_contentflow_guard_social_ops_rara_voice_gate on public.contentflow_build_backlog;
create trigger trg_contentflow_guard_social_ops_rara_voice_gate
before insert or update on public.contentflow_build_backlog
for each row
execute function public.contentflow_guard_social_ops_rara_voice_gate();
