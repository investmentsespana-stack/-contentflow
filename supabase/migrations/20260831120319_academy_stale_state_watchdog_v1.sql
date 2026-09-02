-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_academy_stale_state_watchdog_v1(p_project_key text default 'agent-academy-platform-v1') returns jsonb language plpgsql security definer set search_path='public' as $$
declare v_reopened int:=0; v_incidents int:=0; v_verify int:=0;
begin
  -- Reopen only low-risk internal/unspecified state-guard blocks. External/human gates stay fail-closed.
  with candidates as (
    select id, task_key from public.contentflow_build_backlog
    where project_key=p_project_key
      and status='blocked'
      and execution_lane='llm_artifact'
      and coalesce(blocked_reason,'') in ('STATE_GUARD_BLOCKED_UNSPECIFIED','INTERNAL_STALE_STATE_GUARD_REVIEW_REQUIRED','')
      and updated_at < now()-interval '30 minutes'
  ), upd as (
    update public.contentflow_build_backlog b
    set status='ready', blocked_reason=null, next_eligible_at=now(), workflow_state='artifact_pending', updated_at=now(),
        patch_feedback=coalesce(patch_feedback,'{}'::jsonb) || jsonb_build_object('auto_recovery','academy_stale_state_watchdog_v1','reopened_at',now())
    from candidates c where b.id=c.id returning b.task_key
  ) select count(*) into v_reopened from upd;

  -- Create durable RARA incidents for stale verifications instead of silently idling forever.
  insert into public.director_repair_incidents(project_key,task_key,component,error_class,error_fingerprint,symptom,evidence,risk_level)
  select p_project_key,b.task_key,'verifier','stale_verification','stale_verification:'||b.task_key,
         'verification_required exceeded 30 minutes without terminal decision',
         jsonb_build_object('status',b.status,'updated_at',b.updated_at,'workflow_state',b.workflow_state,'execution_lane',b.execution_lane,'runtime_verified',b.runtime_verified),
         'low'
  from public.contentflow_build_backlog b
  where b.project_key=p_project_key and b.status='verification_required' and b.updated_at<now()-interval '30 minutes'
    and not exists(select 1 from public.director_repair_incidents i where i.project_key=p_project_key and i.error_fingerprint='stale_verification:'||b.task_key and i.status in ('open','analyzing','repairing','validating','needs_help'))
  on conflict do nothing;
  get diagnostics v_verify=row_count;

  -- Surface stale external blockers as incidents for explicit classification/escalation, but never auto-open them.
  insert into public.director_repair_incidents(project_key,task_key,component,error_class,error_fingerprint,symptom,evidence,risk_level,requires_human)
  select p_project_key,b.task_key,'dependency','stale_external_blocker','stale_external_blocker:'||b.task_key,
         coalesce(b.blocked_reason,'external blocker persisted beyond watchdog threshold'),
         jsonb_build_object('status',b.status,'updated_at',b.updated_at,'blocked_reason',b.blocked_reason,'hours_stale',round(extract(epoch from (now()-b.updated_at))/3600,1)),
         'low', true
  from public.contentflow_build_backlog b
  where b.project_key=p_project_key and b.status='blocked' and b.updated_at<now()-interval '2 hours'
    and coalesce(b.blocked_reason,'') not in ('STATE_GUARD_BLOCKED_UNSPECIFIED','INTERNAL_STALE_STATE_GUARD_REVIEW_REQUIRED','')
    and not exists(select 1 from public.director_repair_incidents i where i.project_key=p_project_key and i.error_fingerprint='stale_external_blocker:'||b.task_key and i.status in ('open','analyzing','repairing','validating','needs_help'))
  on conflict do nothing;
  get diagnostics v_incidents=row_count;

  insert into public.director_autonomy_events(project_key,event_type,source,assignment_mode,outcome,required_user_intervention,notes)
  values(p_project_key,'stale_state_watchdog','academy_stale_state_watchdog_v1','automatic_recovery',
         'reopened='||v_reopened||';stale_verification_incidents='||v_verify||';external_blocker_incidents='||v_incidents,
         (v_incidents>0),
         'Low-risk unspecified state guards reopen automatically; stale verifications become RARA incidents; external/human prerequisites remain fail-closed and are escalated explicitly.');

  return jsonb_build_object('reopened_internal',v_reopened,'verification_incidents',v_verify,'external_blocker_incidents',v_incidents);
end $$;
revoke all on function public.contentflow_academy_stale_state_watchdog_v1(text) from public,anon,authenticated;
grant execute on function public.contentflow_academy_stale_state_watchdog_v1(text) to service_role;
