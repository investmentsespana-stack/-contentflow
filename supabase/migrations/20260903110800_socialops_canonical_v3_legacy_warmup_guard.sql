create or replace function public.contentflow_guard_socialops_canonical_v3_legacy()
returns trigger
language plpgsql
security invoker
set search_path='public'
as $$
begin
  if new.project_key='agent-academy-platform-v1'
     and new.task_key like 'academy_today_warmup_%'
     and exists (
       select 1 from public.contentflow_build_backlog c
       where c.project_key=new.project_key
         and c.task_key='academy_social_f02_capture_gate_v3'
         and coalesce(c.workflow_state,'')<>'superseded'
     ) then
    new.status := 'deferred';
    new.completion_phase := 'superseded';
    new.workflow_state := 'superseded';
    new.blocked_reason := 'SUPERSEDED_BY_ACADEMY_SOCIAL_WARMUP_DAG_V3';
    new.next_eligible_at := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_contentflow_socialops_canonical_v3_legacy_guard on public.contentflow_build_backlog;
create trigger trg_contentflow_socialops_canonical_v3_legacy_guard
before insert or update on public.contentflow_build_backlog
for each row
execute function public.contentflow_guard_socialops_canonical_v3_legacy();

update public.contentflow_build_backlog b
set status='deferred',
    completion_phase='superseded',
    workflow_state='superseded',
    blocked_reason='SUPERSEDED_BY_ACADEMY_SOCIAL_WARMUP_DAG_V3',
    next_eligible_at=null,
    updated_at=now()
where b.project_key='agent-academy-platform-v1'
  and b.task_key like 'academy_today_warmup_%'
  and exists (
    select 1 from public.contentflow_build_backlog c
    where c.project_key=b.project_key
      and c.task_key='academy_social_f02_capture_gate_v3'
      and coalesce(c.workflow_state,'')<>'superseded'
  );

delete from public.contentflow_retry_state r
using public.contentflow_build_backlog b
where r.backlog_task_id=b.id
  and b.project_key='agent-academy-platform-v1'
  and b.task_key like 'academy_today_warmup_%'
  and b.workflow_state='superseded';