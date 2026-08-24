-- Recovery-lineage export of the production state introduced by
-- 20260824135547_research_source_materialization_and_state_guard_v1.
-- This file mirrors the currently deployed functions/triggers so a fresh
-- Recovery Snapshot V2 can establish a reproducible baseline.

create or replace function public.contentflow_backlog_state_guard()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
  if new.status='ready' then
    new.blocked_reason:=null;
    new.next_eligible_at:=coalesce(new.next_eligible_at,now());
    update public.contentflow_retry_state set circuit_state='closed',circuit_open_until=null,next_retry_at=null,updated_at=now()
      where project_key=new.project_key and task_key=new.task_key and circuit_state='open';
  elsif new.status='blocked' then
    new.blocked_reason:=coalesce(nullif(new.blocked_reason,''),'STATE_GUARD_BLOCKED_UNSPECIFIED');
    new.next_eligible_at:=coalesce(new.next_eligible_at,now()+interval '7 minutes');
  end if;
  return new;
end
$function$;

create or replace function public.contentflow_materialize_verified_sources_on_review()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
declare ctx text;
begin
  if new.status='review_required' then
    if exists(select 1 from public.contentflow_build_backlog b where b.id=new.backlog_task_id and upper(coalesce(b.acceptance_criteria,'')) like '%OFFICIAL PRIMARY SOURCES%') then
      ctx:=public.contentflow_primary_source_context(new.project_key,new.task_key);
      if ctx<>'NO_VERIFIED_PRIMARY_SOURCES' then
        if position('[VERIFIED PRIMARY SOURCE APPENDIX]' in coalesce(new.result,''))=0 then
          new.result:=coalesce(new.result,'')||E'\n\n[VERIFIED PRIMARY SOURCE APPENDIX]\n'||ctx;
        end if;
      end if;
    end if;
  end if;
  return new;
end
$function$;

drop trigger if exists trg_contentflow_backlog_state_guard on public.contentflow_build_backlog;
create trigger trg_contentflow_backlog_state_guard
before insert or update of status, blocked_reason, next_eligible_at
on public.contentflow_build_backlog
for each row execute function public.contentflow_backlog_state_guard();

drop trigger if exists trg_contentflow_materialize_verified_sources_on_review on public.contentflow_builder_runs;
create trigger trg_contentflow_materialize_verified_sources_on_review
before update of status, result
on public.contentflow_builder_runs
for each row execute function public.contentflow_materialize_verified_sources_on_review();
