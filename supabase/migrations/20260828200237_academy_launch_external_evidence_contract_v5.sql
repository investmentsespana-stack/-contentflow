-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

insert into public.contentflow_evidence_requirements (project_key,backlog_task_id,source_run_id,task_key,requirement_class,requirement_fingerprint,requirement_text,evidence_task_key,status,evidence_ref,created_at,updated_at)
select 'agent-academy-platform-v1',7076,7008,'academy_launch_readiness_gate_v3','gpu_runtime_evidence','academy-launch-v3:gpu-runtime','Verified direct runtime evidence from the Academy GPU VM is required before launch readiness can pass.','academy_gpu_vm_execution_evidence_v2','blocked',jsonb_build_object('policy','direct_observed_runtime_required','source','academy_launch_readiness_gate_v3'),now(),now()
where not exists (select 1 from public.contentflow_evidence_requirements where project_key='agent-academy-platform-v1' and backlog_task_id=7076 and requirement_class='gpu_runtime_evidence' and status<>'obsolete');

insert into public.contentflow_evidence_requirements (project_key,backlog_task_id,source_run_id,task_key,requirement_class,requirement_fingerprint,requirement_text,evidence_task_key,status,evidence_ref,created_at,updated_at)
select 'agent-academy-platform-v1',7076,7008,'academy_launch_readiness_gate_v3','social_access_evidence','academy-launch-v3:social-access','Verified observed social account access evidence is required before launch readiness can pass.','academy_social_access_verification_v2','blocked',jsonb_build_object('policy','observed_external_evidence_only','source','academy_launch_readiness_gate_v3'),now(),now()
where not exists (select 1 from public.contentflow_evidence_requirements where project_key='agent-academy-platform-v1' and backlog_task_id=7076 and requirement_class='social_access_evidence' and status<>'obsolete');

update public.contentflow_build_backlog
set depends_on=(select jsonb_agg(distinct v) from jsonb_array_elements(coalesce(depends_on,'[]'::jsonb) || '["academy_gpu_vm_execution_evidence_v2","academy_social_access_verification_v2"]'::jsonb) e(v)),
workflow_contract=coalesce(workflow_contract,'{}'::jsonb)||jsonb_build_object('external_evidence_contract','academy_launch_external_evidence_contract_v5','required_external_evidence',jsonb_build_array('academy_gpu_vm_execution_evidence_v2','academy_social_access_verification_v2')),
updated_at=now()
where project_key='agent-academy-platform-v1' and task_key='academy_launch_readiness_gate_v3';

update public.contentflow_build_backlog
set status='blocked',completion_phase='runtime_verification',workflow_state='runtime_verification_wait',next_eligible_at=null,
blocked_reason=case when task_key='academy_gpu_vm_execution_evidence_v2' then 'EXTERNAL_VM_EXECUTION_REQUIRED' else 'EXTERNAL_PREREQUISITE_SOCIAL_ACCESS' end,updated_at=now()
where project_key='agent-academy-platform-v1' and task_key in ('academy_gpu_vm_execution_evidence_v2','academy_social_access_verification_v2') and status<>'completed';
