-- CONTENTFLOW_CHANGE_PROVENANCE_V1
-- change-class: recovery
-- lineage-recovered-from-production: true
-- original-statements-sha256: ffddb792126c4fd247528dffb748ea8485222866fc9d18b7b41bd5e0dbf0d826

create or replace function public.internal_builder_collect(p_request_id bigint)
returns text
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
  v_d public.contentflow_builder_dispatches%rowtype;
  v_r net._http_response%rowtype;
  v_j jsonb;
  v_run public.contentflow_builder_runs%rowtype;
  v_ok boolean; v_quality numeric; v_cost numeric; v_model text; v_result text; v_final text;
begin
  select * into v_d from public.contentflow_builder_dispatches where request_id=p_request_id for update;
  if not found then return 'dispatch_not_found'; end if;
  if v_d.status<>'pending' then return v_d.status; end if;
  select * into v_r from net._http_response where id=p_request_id;
  if not found then return 'pending'; end if;
  select * into v_run from public.contentflow_builder_runs where id=v_d.builder_run_id for update;
  if not found then
    update public.contentflow_builder_dispatches set status='failed',collected_at=now(),error='run_missing' where request_id=p_request_id;
    return 'run_missing';
  end if;
  if v_run.lease_revoked_at is not null or exists(select 1 from public.contentflow_builder_runs n where n.backlog_task_id=v_run.backlog_task_id and n.id>v_run.id) then
    update public.contentflow_builder_dispatches set status='superseded',collected_at=now(),http_status=v_r.status_code,error='fenced_out_late_response' where request_id=p_request_id;
    insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload)
    values(v_run.id,v_run.task_key,'late_response_fenced',v_run.idempotency_key,'collector',jsonb_build_object('request_id',p_request_id)) on conflict do nothing;
    return 'superseded';
  end if;
  if v_r.timed_out or v_r.error_msg is not null then
    update public.contentflow_builder_runs set status='failed',error=coalesce(v_r.error_msg,'http_timeout'),finished_at=now(),lease_revoked_at=now() where id=v_run.id;
    update public.contentflow_build_backlog set status='failed',updated_at=now() where id=v_d.backlog_task_id and status='running' and selected_model is not distinct from v_run.selected_model;
    update public.contentflow_builder_dispatches set status='failed',collected_at=now(),http_status=v_r.status_code,error=coalesce(v_r.error_msg,'http_timeout') where request_id=p_request_id;
    update public.director_worker_queue set status='ready',current_task_key=null,last_task_key=v_run.task_key,last_outcome='failed',last_quality_score=0,last_finished_at=now(),total_failures=total_failures+1,updated_at=now() where model_id=v_run.selected_model and current_task_key is not distinct from v_run.task_key;
    return 'failed';
  end if;
  begin v_j:=v_r.content::jsonb; exception when others then v_j:='{}'::jsonb; end;

  if coalesce((v_j->>'accepted')::boolean,false)=true and v_r.status_code between 200 and 299 then
    update public.contentflow_builder_dispatches set status='collected',collected_at=now(),http_status=v_r.status_code,error=null where request_id=p_request_id;
    insert into public.contentflow_runtime_event_ledger(builder_run_id,task_key,event_type,idempotency_key,actor,payload)
    values(v_run.id,v_run.task_key,'async_dispatch_ack_collected',v_run.idempotency_key,'collector',jsonb_build_object('request_id',p_request_id,'http_status',v_r.status_code,'architecture',coalesce(v_j->>'architecture','unknown'))) on conflict do nothing;
    return 'async_accepted';
  end if;

  v_ok:=coalesce((v_j->>'ok')::boolean,false);
  v_quality:=coalesce((v_j->>'quality_score')::numeric,0);
  v_cost:=coalesce((v_j->>'cost_usd')::numeric,0);
  v_model:=nullif(v_j->>'selected_model','');
  v_result:=nullif(v_j->>'result','');
  if v_cost<0 or v_cost>0.05 then v_ok:=false; end if;
  if not v_ok or v_quality<80 then v_final:='failed'; elsif v_run.task_type='code' then v_final:='review_required'; else v_final:='completed'; end if;
  update public.contentflow_builder_runs set status=v_final,selected_model=coalesce(v_model,v_run.selected_model),quality_score=v_quality,cost_usd=least(greatest(v_cost,0),0.05),result=v_result,error=case when v_final='failed' then coalesce(v_j->>'quality_reason',v_j->>'error','quality_or_cost_gate_failed') else null end,review_approved=false,finished_at=case when v_final in ('completed','failed') then now() else null end,lease_revoked_at=case when v_final in ('completed','failed') then now() else lease_revoked_at end where id=v_run.id;
  update public.contentflow_build_backlog set status=case when v_final='review_required' then 'blocked' else v_final end,selected_model=coalesce(v_model,v_run.selected_model),quality_score=v_quality,cost_usd=least(greatest(v_cost,0),0.05),result=v_result,updated_at=now() where id=v_d.backlog_task_id and status='running' and selected_model is not distinct from v_run.selected_model;
  update public.contentflow_builder_dispatches set status='collected',collected_at=now(),http_status=v_r.status_code,error=case when v_final='failed' then coalesce(v_j->>'quality_reason',v_j->>'error') else null end where request_id=p_request_id;
  update public.director_worker_queue set status='ready',current_task_key=null,last_task_key=v_run.task_key,last_outcome=v_final,last_quality_score=v_quality,last_finished_at=now(),total_completions=total_completions+case when v_final in ('completed','review_required') then 1 else 0 end,total_failures=total_failures+case when v_final='failed' then 1 else 0 end,updated_at=now() where model_id=v_run.selected_model and current_task_key is not distinct from v_run.task_key;
  return v_final;
end
$function$;
