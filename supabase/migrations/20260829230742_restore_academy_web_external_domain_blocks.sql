-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

update public.contentflow_build_backlog
set status='blocked',
    workflow_state='runtime_verification_wait',
    blocked_reason='EXTERNAL_PREREQUISITE_WEB_DOMAIN_NOT_ATTACHED_TO_VERCEL_PROJECT',
    next_eligible_at=null,
    selected_model=null,
    updated_at=now()
where project_key='agent-academy-platform-v1'
  and task_key in (
    'academy_web_analytics_runtime_evidence_v1',
    'academy_web_accessibility_runtime_validation_v2',
    'academy_web_error_loading_runtime_validation_v2'
  );
