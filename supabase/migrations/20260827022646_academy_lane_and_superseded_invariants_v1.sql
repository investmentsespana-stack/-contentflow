-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_enforce_backlog_invariants_v1()
returns trigger
language plpgsql
set search_path to 'public'
as $$
declare v_lane text;
begin
  if coalesce(new.epic,'')='evidence_first' or coalesce(new.task_key,'') like 'evidence_%' then
    v_lane:=public.contentflow_classify_execution_lane_fields(new.task_type,new.description,new.acceptance_criteria);
    if v_lane in ('evidence_producer','tool_executor','llm_artifact') then
      new.execution_lane:=v_lane;
    end if;
  end if;

  if coalesce(new.workflow_state,'')='superseded' or coalesce(new.blocked_reason,'') like 'SUPERSEDED_BY_%' then
    new.status:='deferred';
    new.next_eligible_at:=null;
    new.selected_model:=null;
  end if;
  return new;
end
$$;

drop trigger if exists trg_contentflow_backlog_invariants_v1 on public.contentflow_build_backlog;
create trigger trg_contentflow_backlog_invariants_v1
before insert or update on public.contentflow_build_backlog
for each row execute function public.contentflow_enforce_backlog_invariants_v1();
