-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_sync_obsolete_evidence_requirement()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.project_key='contentflow' and new.status='obsolete' and new.evidence_task_key is not null then
    update public.contentflow_build_backlog b
       set blocked_reason='OBSOLETE_EVIDENCE_REQUIREMENT',
           workflow_state='obsolete',
           updated_at=now()
     where b.project_key=new.project_key
       and b.task_key=new.evidence_task_key
       and b.status='deferred';
  end if;
  return new;
end
$function$;

drop trigger if exists trg_contentflow_sync_obsolete_evidence_requirement on public.contentflow_evidence_requirements;
create trigger trg_contentflow_sync_obsolete_evidence_requirement
after insert or update of status on public.contentflow_evidence_requirements
for each row execute function public.contentflow_sync_obsolete_evidence_requirement();

update public.contentflow_build_backlog b
   set blocked_reason='OBSOLETE_EVIDENCE_REQUIREMENT',
       workflow_state='obsolete',
       updated_at=now()
 where b.project_key='contentflow'
   and b.status='deferred'
   and exists(
     select 1
     from public.contentflow_evidence_requirements er
     where er.project_key=b.project_key
       and er.evidence_task_key=b.task_key
       and er.status='obsolete'
   );

update public.director_error_memory
set correction=correction||' Obsolete evidence requirements now propagate a structural terminal marker to deferred evidence tasks.',
    prevention_rule=prevention_rule||' Any evidence requirement transitioning to obsolete must terminalize its deferred evidence task in the same transaction boundary.',
    updated_at=now(),last_seen_at=now()
where project_key='contentflow' and error_fingerprint='durable_wait_signal_contract_v2';
