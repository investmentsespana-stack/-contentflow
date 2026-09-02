-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.academy_configure_web_runtime_executor_v1()
returns jsonb
language plpgsql
security definer
set search_path=public
as $$
declare v_count int:=0;
begin
  update public.contentflow_build_backlog
  set execution_lane='tool_executor',
      status='ready',
      workflow_state='artifact_pending',
      completion_phase='runtime_verification',
      blocked_reason=null,
      next_eligible_at=now(),
      workflow_contract=workflow_contract || jsonb_build_object(
        'environment','live_public_web',
        'no_retry_without_new_evidence',false,
        'execution_recipe',jsonb_build_object(
          'handler','edge_function',
          'function','academy-web-runtime-evidence',
          'mode',case task_key
             when 'academy_web_analytics_runtime_evidence_v1' then 'analytics'
             when 'academy_web_accessibility_runtime_validation_v2' then 'accessibility'
             else 'error_loading' end,
          'target','academy_public_web',
          'deterministic',true
        )
      )
  where project_key='agent-academy-platform-v1'
    and task_key in (
      'academy_web_analytics_runtime_evidence_v1',
      'academy_web_accessibility_runtime_validation_v2',
      'academy_web_error_loading_runtime_validation_v2'
    );
  get diagnostics v_count=row_count;
  return jsonb_build_object('configured',v_count,'architecture','ACADEMY_PARALLEL_WEB_RUNTIME_EXECUTOR_V1');
end $$;
select public.academy_configure_web_runtime_executor_v1();
