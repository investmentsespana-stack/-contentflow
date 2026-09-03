-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

update public.contentflow_build_backlog
set status='deferred',
    workflow_state='superseded',
    completion_phase='superseded',
    blocked_reason='SUPERSEDED_BY_ACADEMY_SOCIAL_MEDIA_RENDER_F06_F09_V4',
    next_eligible_at=null,
    updated_at=now()
where project_key='agent-academy-platform-v1'
  and task_key='academy_social_gpu_render_f06_f09_v3';

insert into public.contentflow_build_backlog(
  project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,
  acceptance_criteria,execution_lane,completion_phase,workflow_state,workflow_contract,next_eligible_at,updated_at,blocked_reason
)
select
  'agent-academy-platform-v1',
  'academy_social_warmup_today_deep_funnel_hir',
  'academy_social_media_render_f06_f09_v4',
  'F06/F09 — GitHub Actions media render v4',
  'Render real professional vertical MP4 review cuts for F06 and F09 from deterministic sanitized source evidence. This lane must not require Nebius/GPU unless the creative explicitly includes a professor/avatar. Publication remains closed.',
  'general',
  4,
  '["academy_social_f06_verified_evidence_pack_v3","academy_social_f09_verified_evidence_pack_v3"]'::jsonb,
  'social-ops:github-media-executor',
  'blocked',
  100,
  'Produce F06 master + short and F09 master + short as 1080x1920 MP4; generate subtitles/keyframes/SHA-256 manifest; evidence provenance must point to deterministic F06/F09 source evidence; no invented runtime claims; publication_authorized=false.',
  'tool_executor',
  'render_pending',
  'external_prerequisite',
  jsonb_build_object(
    'contract_version','4',
    'runtime_required',true,
    'publication_authorized',false,
    'execution_recipe',jsonb_build_object(
      'handler','external_github_actions_oidc',
      'workflow','academy-social-warmup-render.yml',
      'repo','investmentsespana-stack/avatar-platform',
      'gpu_required',false,
      'deterministic',true
    ),
    'evidence_source','academy_social_source_evidence_task_v4'
  ),
  null,now(),'EXTERNAL_GITHUB_ACTIONS_EXECUTOR_WAIT'
where not exists(
  select 1 from public.contentflow_build_backlog
  where project_key='agent-academy-platform-v1'
    and task_key='academy_social_media_render_f06_f09_v4'
);

update public.contentflow_build_backlog
set depends_on='["academy_social_media_render_f06_f09_v4"]'::jsonb,
    status='planned',
    blocked_reason=null,
    next_eligible_at=null,
    updated_at=now()
where project_key='agent-academy-platform-v1'
  and task_key='academy_social_rara_final_f06_f09_v3';
