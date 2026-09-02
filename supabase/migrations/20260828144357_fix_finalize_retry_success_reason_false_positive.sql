-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

CREATE OR REPLACE FUNCTION public.contentflow_finalize_run_v2(p_run_id bigint, p_lease_token text, p_http_status integer, p_payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
declare r public.contentflow_builder_runs%rowtype; b public.contentflow_build_backlog%rowtype; v_ok boolean; v_quality numeric; v_cost numeric; v_model text; v_result text; v_failure text; v_run_final text; v_backlog_final text; v_reason text; v_dep_incomplete int:=0; v_contract boolean:=false; v_retryable boolean:=false; v_patchable boolean:=false;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 select * into r from public.contentflow_builder_runs where id=p_run_id for update; if not found then return jsonb_build_object('ok',false,'reason','run_not_found'); end if;
 select * into b from public.contentflow_build_backlog where id=r.backlog_task_id for update; if not found then return jsonb_build_object('ok',false,'reason','backlog_not_found'); end if;
 if r.lease_token is distinct from p_lease_token or r.lease_revoked_at is not null or r.status not in ('claimed','running') or b.status<>'running' or exists(select 1 from public.contentflow_builder_runs n where n.backlog_task_id=r.backlog_task_id and n.id>r.id) then update public.contentflow_builder_dispatches set status='superseded',collected_at=now(),http_status=p_http_status,error='fenced_out_or_commit_state_invalid' where builder_run_id=r.id and status='pending'; return jsonb_build_object('ok',false,'reason','commit_fenced','run_id',r.id); end if;
 if b.depends_on is not null then select count(*) into v_dep_incomplete from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(dep) where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.dep and x.status='completed'); end if;
 v_ok:=coalesce((p_payload->>'ok')::boolean,false); v_quality:=coalesce((p_payload->>'quality_score')::numeric,0); v_cost:=coalesce((p_payload->>'cost_usd')::numeric,0); v_model:=nullif(p_payload->>'selected_model',''); v_result:=nullif(p_payload->>'result',''); v_failure:=upper(coalesce(p_payload->>'failure_class','')); v_reason:=coalesce(p_payload->>'quality_reason',p_payload->>'error','execution_failed'); v_contract:=coalesce(b.workflow_contract->>'contract_version','')<>'';
 -- Retry classification is only meaningful for unsuccessful executions. A successful
 -- judge reason may legitimately contain words such as "timeout", "rate limit", etc.
 -- and must never be reclassified as transport failure.
 v_retryable:=(not v_ok) and (v_failure='INFRA_FAIL' or p_http_status in (408,425,429,500,502,503,504) or lower(v_reason) ~ '(transport|timeout|capacity|rate.limit|upstream|network|fenced)');
 v_patchable:=v_contract and coalesce(b.workflow_contract->>'failure_policy','')='patch_stage_only';
 if v_cost<0 or v_cost>0.05 then v_ok:=false; v_reason:='cost_gate_failed'; v_retryable:=false; end if;
 if v_dep_incomplete>0 then v_ok:=false; v_reason:='dependency_commit_gate_failed'; v_retryable:=false; end if;
 if v_retryable then v_run_final:='deferred'; v_backlog_final:='ready';
 elsif v_failure='JUDGE_FAIL' and v_result is not null then v_run_final:='review_required'; v_backlog_final:='blocked';
 elsif v_ok and v_quality>=85 then v_run_final:='review_required'; v_backlog_final:='blocked';
 elsif v_patchable then v_run_final:='failed'; v_backlog_final:='ready';
 else v_run_final:='failed'; v_backlog_final:='failed'; end if;
 update public.contentflow_builder_runs set status=v_run_final,selected_model=coalesce(v_model,r.selected_model),quality_score=v_quality,cost_usd=least(greatest(v_cost,0),0.05),result=coalesce(v_result,r.result),error=case when v_run_final in ('failed','deferred') or (v_run_final='review_required' and v_failure='JUDGE_FAIL') then v_reason else null end,review_approved=false,finished_at=case when v_run_final in ('failed','deferred') then now() else null end,lease_revoked_at=now(),activity_phase=null,activity_deadline_at=null,heartbeat_deadline_at=null where id=r.id;
 update public.contentflow_build_backlog set status=v_backlog_final,blocked_reason=case when v_run_final='review_required' then 'REVIEW_PENDING' else null end,selected_model=case when v_backlog_final='ready' then null else coalesce(v_model,r.selected_model) end,quality_score=case when v_run_final='review_required' then v_quality else quality_score end,cost_usd=least(greatest(v_cost,0),0.05),result=coalesce(v_result,result),next_eligible_at=case when v_retryable then now()+interval '15 seconds' when v_patchable and v_run_final='failed' then now()+interval '10 seconds' else next_eligible_at end,workflow_state=case when v_patchable and v_run_final='failed' then 'patch_required' else workflow_state end,patch_feedback=case when v_patchable and v_run_final='failed' then left(v_reason,5000) else patch_feedback end,updated_at=now() where id=r.backlog_task_id and status='running';
 update public.director_worker_queue set status='ready',current_task_key=null,last_task_key=r.task_key,last_outcome=v_run_final,last_quality_score=v_quality,last_finished_at=now(),total_completions=total_completions+case when v_run_final='review_required' then 1 else 0 end,total_failures=total_failures+case when v_run_final='failed' and not v_patchable then 1 else 0 end,updated_at=now() where model_id=r.selected_model and current_task_key is not distinct from r.task_key;
 update public.contentflow_builder_dispatches set status='collected',collected_at=now(),http_status=p_http_status,error=case when v_run_final in ('failed','deferred') then v_reason else null end where builder_run_id=r.id and status='pending';
 perform public.contentflow_checkpoint_stage(b.id,case when v_run_final='review_required' then 'review' else 'artifact' end,case when v_run_final='review_required' then 'pending' when v_retryable then 'retry_wait' when v_patchable then 'patch_required' else 'failed' end,case when v_retryable then 'transient_infra' when v_patchable then 'artifact_defect' else 'fatal' end,v_reason,jsonb_build_object('run_id',r.id,'http_status',p_http_status,'failure_class',v_failure,'typed_retry',v_retryable));
 insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload) values(r.id,r.task_key,'owner_finalized',r.idempotency_key,'dispatch_executor_v2',jsonb_build_object('final_status',v_run_final,'backlog_status',v_backlog_final,'http_status',p_http_status,'quality_score',v_quality,'typed_retry',v_retryable,'dependency_commit_gate',v_dep_incomplete=0)) on conflict do nothing;
 return jsonb_build_object('ok',true,'run_id',r.id,'final_status',v_run_final,'backlog_status',v_backlog_final,'quality_score',v_quality,'typed_retry',v_retryable,'dependency_commit_gate',v_dep_incomplete=0);
end
$function$;
