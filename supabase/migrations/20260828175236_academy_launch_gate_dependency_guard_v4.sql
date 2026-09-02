-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

update public.contentflow_build_backlog
set depends_on = (select jsonb_agg(distinct v) from jsonb_array_elements(coalesce(depends_on,'[]'::jsonb) || '["academy_web_launch_qa_seo_v3","academy_gpu_vm_execution_evidence_v2","academy_social_access_verification_v2"]'::jsonb) e(v)),
    workflow_contract = coalesce(workflow_contract,'{}'::jsonb) || jsonb_build_object('contract_version','3','required_external_evidence',jsonb_build_array('academy_gpu_vm_execution_evidence_v2','academy_social_access_verification_v2'),'evidence_policy','verified_evidence_required'),
    updated_at=now()
where project_key='agent-academy-platform-v1' and task_key='academy_launch_readiness_gate_v3';

update public.contentflow_build_backlog
set status='blocked', completion_phase='runtime_verification', workflow_state='runtime_verification_wait', next_eligible_at=null,
    blocked_reason=case when task_key='academy_gpu_vm_execution_evidence_v2' then 'EXTERNAL_VM_EXECUTION_REQUIRED' else 'EXTERNAL_PREREQUISITE_SOCIAL_ACCESS' end,
    updated_at=now()
where project_key='agent-academy-platform-v1' and task_key in ('academy_gpu_vm_execution_evidence_v2','academy_social_access_verification_v2') and status='deferred' and completion_phase='orphan_evidence_retired';

update public.contentflow_build_backlog
set selected_model='Qwen/Qwen3-Max', next_eligible_at=now(), updated_at=now()
where project_key='agent-academy-platform-v1' and task_key='academy_web_launch_qa_seo_v3' and status='ready';
