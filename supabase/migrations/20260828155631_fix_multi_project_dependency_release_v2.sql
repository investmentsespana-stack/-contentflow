-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_sync_dependency_states(p_project_key text default 'contentflow'::text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare demoted int:=0; promoted int:=0;
begin
  update public.contentflow_build_backlog b
     set status='planned',selected_model=null,blocked_reason='DEPENDENCY_INCOMPLETE',next_eligible_at=null,updated_at=now()
   where b.project_key=p_project_key
     and b.status='ready'
     and exists(
       select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
       where not exists(
         select 1 from public.contentflow_build_backlog d
         where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'
       )
     );
  get diagnostics demoted=row_count;

  update public.contentflow_build_backlog b
     set status='ready',selected_model=null,blocked_reason=null,next_eligible_at=now(),updated_at=now()
   where b.project_key=p_project_key
     and b.status in ('planned','blocked')
     and b.task_key not like 'gap_gap_%'
     and not exists(
       select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
       where not exists(
         select 1 from public.contentflow_build_backlog d
         where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'
       )
     )
     and not exists(
       select 1 from public.contentflow_retry_state rs
       where rs.backlog_task_id=b.id and rs.circuit_state='open'
     )
     and not (b.blocked_reason='EXTERNAL_LEGAL_AND_OWNER_PRODUCTION_APPROVAL_REQUIRED');
  get diagnostics promoted=row_count;

  return jsonb_build_object('architecture','DEPENDENCY_STATE_SYNC_V2_MULTI_PROJECT','demoted_waiting',demoted,'promoted_dispatchable',promoted);
end
$function$;

create or replace function public.contentflow_sync_help_and_dependents()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.status='completed' and old.status is distinct from new.status then
    update public.director_help_alerts
       set status='resolved', resolved_at=now(), updated_at=now(),
           summary=coalesce(summary,'') || case when coalesce(summary,'')='' then '' else ' | ' end || 'AUTO_RESOLVED_FROM_BACKLOG_COMPLETION'
     where project_key=new.project_key and task_key=new.task_key and status='open';

    update public.contentflow_build_backlog p
       set status='ready', updated_at=now(), selected_model=null, blocked_reason=null, next_eligible_at=now()
     where p.project_key=new.project_key
       and p.status in ('blocked','planned')
       and p.blocked_reason is distinct from 'EXTERNAL_LEGAL_AND_OWNER_PRODUCTION_APPROVAL_REQUIRED'
       and jsonb_array_length(coalesce(p.depends_on,'[]'::jsonb)) > 0
       and not exists (
         select 1
           from jsonb_array_elements_text(coalesce(p.depends_on,'[]'::jsonb)) d(dep)
           left join public.contentflow_build_backlog q
             on q.project_key=new.project_key and q.task_key=d.dep
          where coalesce(q.status,'missing') <> 'completed'
       )
       and not exists(
         select 1 from public.contentflow_retry_state rs
         where rs.backlog_task_id=p.id and rs.circuit_state='open'
       );
  end if;
  return new;
end
$function$;
