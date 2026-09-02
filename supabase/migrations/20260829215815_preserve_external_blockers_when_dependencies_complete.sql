-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

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
       and (
         p.status='planned'
         or coalesce(p.blocked_reason,'') in ('','STATE_GUARD_BLOCKED_UNSPECIFIED')
       )
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
