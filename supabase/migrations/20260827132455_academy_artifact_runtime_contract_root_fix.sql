-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_default_artifact_contract_v1()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if coalesce(new.workflow_contract,'{}'::jsonb)='{}'::jsonb then
    if coalesce(new.description,'') ~* '(specification only unless runtime evidence exists|do not claim live deployment or runtime evidence unless persisted evidence exists|do not fabricate image assets or claim that they exist|bounded implementation artifact)' then
      new.workflow_contract := jsonb_build_object(
        'contract_version','1',
        'runtime_required',false,
        'evidence_policy','declared_gaps_allowed',
        'artifact_kind',coalesce(nullif(new.task_type,''),'artifact')
      );
    end if;
  end if;
  return new;
end
$$;

drop trigger if exists trg_contentflow_default_artifact_contract_v1 on public.contentflow_build_backlog;
create trigger trg_contentflow_default_artifact_contract_v1
before insert or update of description,task_type,workflow_contract on public.contentflow_build_backlog
for each row execute function public.contentflow_default_artifact_contract_v1();

update public.contentflow_build_backlog
set workflow_contract=jsonb_build_object('contract_version','1','runtime_required',false,'evidence_policy','declared_gaps_allowed','artifact_kind',coalesce(nullif(task_type,''),'artifact')),updated_at=now()
where project_key='agent-academy-platform-v1'
  and task_key in ('academy_methodology_visualizer_remediation_v1','academy_growth_attribution_remediation_v1','academy_social_visual_evidence_remediation_v1')
  and coalesce(workflow_contract,'{}'::jsonb)='{}'::jsonb;

update public.contentflow_build_backlog
set workflow_state='superseded',status='deferred',blocked_reason='SUPERSEDED_BY_academy_experience_integration_gate_v2',next_eligible_at=null,selected_model=null,updated_at=now()
where project_key='agent-academy-platform-v1' and task_key='academy_experience_integration_gate_v1';

update public.contentflow_build_backlog
set workflow_state='superseded',status='deferred',blocked_reason='SUPERSEDED_BY_academy_customer_data_model_v2',next_eligible_at=null,selected_model=null,updated_at=now()
where project_key='agent-academy-platform-v1' and task_key='academy_customer_data_model_v1';

update public.contentflow_builder_runs r
set status='completed',finished_at=coalesce(finished_at,now()),error=null
from public.contentflow_build_backlog b
where r.backlog_task_id=b.id
  and b.project_key='agent-academy-platform-v1'
  and b.task_key in ('academy_methodology_visualizer_remediation_v1','academy_growth_attribution_remediation_v1')
  and r.status='verification_required'
  and r.review_approved=true
  and coalesce(r.quality_score,0)>=85
  and r.result is not null and length(trim(r.result))>=40;

update public.contentflow_build_backlog b
set status='completed',workflow_state='completed',completion_phase='artifact_approved',blocked_reason=null,next_eligible_at=null,updated_at=now()
where b.project_key='agent-academy-platform-v1'
  and b.task_key in ('academy_methodology_visualizer_remediation_v1','academy_growth_attribution_remediation_v1')
  and b.status='verification_required'
  and coalesce((b.workflow_contract->>'runtime_required')::boolean,false)=false
  and exists(select 1 from public.contentflow_builder_runs r where r.backlog_task_id=b.id and r.status='completed' and r.review_approved=true and coalesce(r.quality_score,0)>=85 and r.result is not null and length(trim(r.result))>=40);
