-- CONTENTFLOW_CHANGE_PROVENANCE_V1
-- change-class: recovery
-- lineage-recovered-from-production: true
-- original-statements-sha256: 041061a8dea16509da29c9683ed76855c5704efab7712bb9778299ec03b5ddcb

create or replace function public.contentflow_classify_run_error(p_error text)
returns text
language sql
immutable
set search_path to 'public','pg_temp'
as $function$
 select case
   when coalesce(p_error,'') ilike '%artifact_truncated%' or coalesce(p_error,'') ilike '%TRUNCATED_RESPONSE%' then 'artifact_truncation'
   when coalesce(p_error,'') ilike '%nexo_lane_capacity_limited%' or coalesce(p_error,'') ilike '%capacity%' or coalesce(p_error,'') ilike '%429%' or coalesce(p_error,'') ilike '%rate_limit%' then 'capacity'
   when coalesce(p_error,'') ilike '%judge_unavailable%' or coalesce(p_error,'') ilike '%judge_unavailable_or_unparseable%' then 'judge'
   when coalesce(p_error,'') ilike '%worker_transport_failed%' or coalesce(p_error,'') ilike '%transport_failed%' or coalesce(p_error,'') ilike '%worker_provider_failed%' or coalesce(p_error,'') ilike '%provider_failed%' or coalesce(p_error,'') ilike '%runner_response_parse_failed%' or coalesce(p_error,'') ilike '%runner_response_parse%' then 'provider'
   when coalesce(p_error,'') ilike '%timeout%' or coalesce(p_error,'') ilike '%120000 ms%' then 'timeout'
   when coalesce(p_error,'') ilike '%ORPHAN_CLAIM%' or coalesce(p_error,'') ilike '%lease_expired%' or coalesce(p_error,'') ilike '%LEASE_REVOKED%' or coalesce(p_error,'') ilike '%stale_claim%' or coalesce(p_error,'') ilike '%worker_claim_race%' or coalesce(p_error,'') ilike '%fenced_out%' then 'state_recovery'
   when coalesce(p_error,'') ilike '%RARA_REVIEW_REJECTED%' then 'quality_review'
   when coalesce(p_error,'') ilike '%quality_or_cost_gate_failed%' then 'quality_gate'
   when coalesce(p_error,'') ilike '%REVIEW_REJECTED_AUTONOMOUS_SLA%' or coalesce(p_error,'') ilike '%Evidence not correlated%' or coalesce(p_error,'') ilike '%evidence missing%' or coalesce(p_error,'') ilike '%missing platform evidence%' or coalesce(p_error,'') ilike '%acceptance criterion%' then 'acceptance_evidence'
   else 'unknown' end;
$function$;

create or replace function public.contentflow_reconcile_retry_policies(p_project_key text default 'contentflow'::text, p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare x record; n int:=0; scheduled int:=0; blocked int:=0; a jsonb; cleaned int:=0; begin
  with obsolete as (
    select s.backlog_task_id
    from public.contentflow_retry_state s
    join public.contentflow_build_backlog b on b.id=s.backlog_task_id
    left join public.contentflow_builder_runs lr on lr.id=s.last_run_id
    where s.project_key=p_project_key
      and (
        b.status='completed'
        or coalesce(b.workflow_state,'')='superseded'
        or coalesce(b.blocked_reason,'') like 'SUPERSEDED_BY_%'
        or lr.id is null
        or lr.status not in ('failed','deferred')
        or exists(select 1 from public.contentflow_builder_runs newer where newer.backlog_task_id=s.backlog_task_id and newer.id>s.last_run_id)
        or (
          coalesce(b.epic,'') in ('evidence_capability','evidence_capability_root','capability_bootstrap')
          and b.status in ('ready','planned')
          and lr.finished_at is not null
          and b.updated_at>lr.finished_at
        )
      )
  )
  delete from public.contentflow_retry_state s using obsolete o where s.backlog_task_id=o.backlog_task_id;
  get diagnostics cleaned=row_count;

  for x in
    select r.id
    from public.contentflow_builder_runs r
    join public.contentflow_build_backlog b on b.id=r.backlog_task_id
    left join public.contentflow_retry_state s on s.backlog_task_id=b.id
    where r.project_key=p_project_key
      and b.status<>'completed'
      and coalesce(b.workflow_state,'')<>'superseded'
      and coalesce(b.blocked_reason,'') not like 'SUPERSEDED_BY_%'
      and r.status in ('failed','deferred') and r.finished_at is not null
      and s.last_run_id is distinct from r.id
      and r.id=(select max(z.id) from public.contentflow_builder_runs z where z.backlog_task_id=r.backlog_task_id and z.finished_at is not null)
      and not exists(
        select 1 from public.contentflow_builder_runs active
        where active.backlog_task_id=b.id and active.status in ('claimed','running','review_required','verification_required') and active.finished_at is null
      )
      and not (
        coalesce(b.epic,'') in ('evidence_capability','evidence_capability_root','capability_bootstrap')
        and b.status in ('ready','planned')
        and b.updated_at>r.finished_at
      )
    order by r.id asc limit greatest(1,least(coalesce(p_limit,100),500))
  loop
    a:=public.contentflow_apply_retry_policy(x.id); n:=n+1;
    if a->>'action'='retry_scheduled' then scheduled:=scheduled+1; elsif a->>'action'='blocked_for_repair' then blocked:=blocked+1; end if;
  end loop;
  update public.contentflow_retry_state set circuit_state='closed',circuit_open_until=null where project_key=p_project_key and circuit_state='cooldown' and next_retry_at<=now();
  return jsonb_build_object('examined',n,'scheduled',scheduled,'blocked',blocked,'obsolete_cleaned',cleaned,'active_run_protected',true,'bootstrap_repair_protected',true,'superseded_guard',true);
end
$function$;
