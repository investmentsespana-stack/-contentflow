-- CONTENTFLOW_CHANGE_PROVENANCE_V1
-- change-class: recovery
-- lineage-recovered-from-production: true
-- original-statements-sha256: 928c6cee7e7d5b11ae1f480376f8368668e3368583ebe1d166d90262dda9c1c4

create or replace function public.rara_apply_review_decision_v2(p_builder_run_id bigint, p_claim_token text, p_approve boolean, p_reason text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  q public.contentflow_review_work_queue%rowtype;
  d jsonb;
  l jsonb;
  b public.contentflow_build_backlog%rowtype;
  effective_approve boolean := p_approve;
  normalized_reason text := coalesce(p_reason,'');
begin
  if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
  if not effective_approve
     and normalized_reason ilike '%class=NONE%'
     and normalized_reason ilike '%action=COMPLETE%'
     and normalized_reason ilike '%missing=[]%'
     and normalized_reason ilike '%gate=false%'
     and normalized_reason ilike '%contract={}%' then
    effective_approve := true;
  end if;
  select * into q from public.contentflow_review_work_queue where builder_run_id=p_builder_run_id for update;
  if not found then return jsonb_build_object('ok',false,'reason','review_claim_not_found'); end if;
  if q.state<>'claimed' or q.claim_token is distinct from p_claim_token then return jsonb_build_object('ok',false,'reason','review_claim_fenced'); end if;
  d:=public.rara_apply_review_decision(p_builder_run_id,effective_approve,normalized_reason);
  if coalesce((d->>'ok')::boolean,false)=false and effective_approve and d->>'reason' in ('deterministic_evidence_gate_failed','deterministic_stage_gate_failed') then
    d:=public.rara_apply_review_decision(p_builder_run_id,false,'Deterministic stage gate failed at commit: '||normalized_reason);
  end if;
  if coalesce((d->>'ok')::boolean,false)=false then
    update public.contentflow_review_work_queue set state='pending',claim_token=null,claimed_at=null,available_at=now()+interval '60 seconds',last_error=left(coalesce(d->>'reason','decision_failed'),1000),updated_at=now() where builder_run_id=p_builder_run_id and state='claimed' and claim_token=p_claim_token;
    return d;
  end if;
  update public.contentflow_review_work_queue set state='done',claim_token=null,claimed_at=null,updated_at=now() where builder_run_id=p_builder_run_id and claim_token=p_claim_token;
  if coalesce(d->>'decision','') in ('rejected_patch_required','rejected_requeued') then
    l:=public.rara_learn_and_replan_rejection(p_builder_run_id,normalized_reason); d:=d||jsonb_build_object('learning',l);
    if coalesce(l->>'action','')='owner_required' then
      select b2.* into b from public.contentflow_build_backlog b2 join public.contentflow_builder_runs r on r.backlog_task_id=b2.id where r.id=p_builder_run_id;
      update public.contentflow_build_backlog set status='blocked',blocked_reason='OWNER_REQUIRED',workflow_state='external_approval_wait',selected_model=null,next_eligible_at=null,updated_at=now() where id=b.id;
      insert into public.director_repair_incidents(project_key,component,error_class,error_fingerprint,symptom,status,risk_level,requires_human,diagnosis,root_cause,proposed_action) values(b.project_key,'rara_review','owner_required','rara_owner_required_v2',left(normalized_reason,1000),'needs_help','high',true,'Explicit workflow contract requires owner authority','True non-autonomous authority boundary','Request explicit owner/counsel approval') on conflict do nothing;
    end if;
  end if;
  return d;
end
$$;
