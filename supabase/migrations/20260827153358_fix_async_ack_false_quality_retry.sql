-- CONTENTFLOW_CHANGE_PROVENANCE_V1
-- change-class: recovery
-- lineage-recovered-from-production: true
-- original-statements-sha256: 24fe7baa9acb97ef2a8a2f0608e3d935449e767b58336c80392993811b98d2e4

create or replace function public.contentflow_apply_retry_policy(p_run_id bigint)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare
 r public.contentflow_builder_runs%rowtype;
 b public.contentflow_build_backlog%rowtype;
 p public.contentflow_retry_policies%rowtype;
 s public.contentflow_retry_state%rowtype;
 cls text; att int; base_delay numeric; jitter numeric; delay_s int; next_at timestamptz;
 deps_complete boolean:=true;
 target_status text;
 late_judge_pass boolean:=false;
 late_runner_pass boolean:=false;
begin
 select * into r from public.contentflow_builder_runs where id=p_run_id;
 if not found or r.status not in ('failed','deferred') then return jsonb_build_object('applied',false,'reason','run_not_failed'); end if;
 select * into b from public.contentflow_build_backlog where id=r.backlog_task_id for update;
 if not found then return jsonb_build_object('applied',false,'reason','backlog_missing'); end if;

 -- Durable async-ACK race guard: an old collector could mark a run quality=0/failed
 -- on the HTTP 202 acknowledgement while the async runner was still working.
 -- If the same run later emitted successful judge+runner completion events, that
 -- failure is transport/control-plane noise and must never reopen a quality circuit.
 if coalesce(r.error,'') ilike '%quality_or_cost_gate_failed%' then
   select
     coalesce(bool_or((payload->>'pass')::boolean) filter(where event_type='judge_completed'),false),
     coalesce(bool_or((payload->>'pass')::boolean) filter(where event_type='runner_completed'),false)
   into late_judge_pass,late_runner_pass
   from public.contentflow_runtime_event_ledger
   where builder_run_id=r.id;
   if late_judge_pass and late_runner_pass then
     delete from public.contentflow_retry_state where backlog_task_id=b.id;
     update public.contentflow_build_backlog
        set status=case when not exists(
              select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d(dep)
              where not exists(select 1 from public.contentflow_build_backlog x where x.project_key=b.project_key and x.task_key=d.dep and x.status='completed')
            ) then 'ready' else 'planned' end,
            selected_model=null,blocked_reason=null,
            next_eligible_at=case when not exists(
              select 1 from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) d2(dep)
              where not exists(select 1 from public.contentflow_build_backlog x2 where x2.project_key=b.project_key and x2.task_key=d2.dep and x2.status='completed')
            ) then now() else next_eligible_at end,
            updated_at=now()
      where id=b.id and status<>'completed';
     insert into public.contentflow_runtime_event_ledger(project_key,builder_run_id,task_key,event_type,idempotency_key,actor,payload,trace_id)
     values(b.project_key,r.id,b.task_key,'false_quality_failure_tombstoned',r.idempotency_key,'director_retry_policy',
       jsonb_build_object('reason','async_ack_race','judge_pass',late_judge_pass,'runner_pass',late_runner_pass),r.trace_id)
     on conflict do nothing;
     return jsonb_build_object('applied',true,'action','false_quality_failure_tombstoned','run_id',r.id,'task_key',b.task_key);
   end if;
 end if;

 cls:=public.contentflow_classify_run_error(r.error);
 select * into p from public.contentflow_retry_policies where error_class=cls;
 select * into s from public.contentflow_retry_state where backlog_task_id=b.id for update;
 if found and s.last_run_id=r.id then return jsonb_build_object('applied',false,'reason','already_processed','class',cls,'attempt',s.attempt_count); end if;
 att:=case when found and s.error_class=cls then s.attempt_count+1 else 1 end;

 select not exists(
   select 1
   from jsonb_array_elements_text(coalesce(b.depends_on,'[]'::jsonb)) dep(value)
   where not exists(
     select 1 from public.contentflow_build_backlog d
     where d.project_key=b.project_key and d.task_key=dep.value and d.status='completed'
   )
 ) into deps_complete;

 if p.retryable and att<=p.max_attempts then
   base_delay:=least(p.max_backoff_seconds::numeric,p.initial_backoff_seconds*power(p.backoff_coefficient,att-1));
   jitter:=((('x'||substr(md5(b.task_key||':'||r.id::text),1,8))::bit(32)::bigint % 10001)::numeric/10000.0*2-1)*p.jitter_ratio;
   delay_s:=greatest(1,round(base_delay*(1+jitter))::int);
   next_at:=now()+make_interval(secs=>delay_s);
   target_status:=case when deps_complete then 'ready' else 'planned' end;
   insert into public.contentflow_retry_state(backlog_task_id,project_key,task_key,error_class,attempt_count,last_run_id,last_error,last_model,next_retry_at,circuit_state,circuit_open_until,updated_at)
   values(b.id,b.project_key,b.task_key,cls,att,r.id,r.error,r.selected_model,next_at,'cooldown',next_at,now())
   on conflict(backlog_task_id) do update set error_class=excluded.error_class,attempt_count=excluded.attempt_count,last_run_id=excluded.last_run_id,last_error=excluded.last_error,last_model=excluded.last_model,next_retry_at=excluded.next_retry_at,circuit_state='cooldown',circuit_open_until=excluded.circuit_open_until,updated_at=now();
   update public.contentflow_build_backlog
      set status=target_status,selected_model=null,next_eligible_at=next_at,updated_at=now()
    where id=b.id and status in ('failed','blocked','ready','planned');
   insert into public.contentflow_runtime_event_ledger(project_key,builder_run_id,task_key,event_type,idempotency_key,actor,payload,trace_id)
   values(b.project_key,r.id,b.task_key,'retry_scheduled',r.idempotency_key,'director_retry_policy',jsonb_build_object('error_class',cls,'attempt',att,'delay_seconds',delay_s,'next_retry_at',next_at,'switch_model',p.switch_model_on_retry,'dependencies_complete',deps_complete,'target_status',target_status),r.trace_id)
   on conflict do nothing;
   return jsonb_build_object('applied',true,'action','retry_scheduled','class',cls,'attempt',att,'next_retry_at',next_at,'delay_seconds',delay_s,'dependencies_complete',deps_complete,'target_status',target_status);
 else
   insert into public.contentflow_retry_state(backlog_task_id,project_key,task_key,error_class,attempt_count,last_run_id,last_error,last_model,next_retry_at,circuit_state,circuit_open_until,updated_at)
   values(b.id,b.project_key,b.task_key,cls,att,r.id,r.error,r.selected_model,null,'open',null,now())
   on conflict(backlog_task_id) do update set error_class=excluded.error_class,attempt_count=excluded.attempt_count,last_run_id=excluded.last_run_id,last_error=excluded.last_error,last_model=excluded.last_model,next_retry_at=null,circuit_state='open',circuit_open_until=null,updated_at=now();
   update public.contentflow_build_backlog set status='blocked',selected_model=null,next_eligible_at=null,updated_at=now() where id=b.id and status in ('failed','ready','planned','blocked');
   insert into public.contentflow_runtime_event_ledger(project_key,builder_run_id,task_key,event_type,idempotency_key,actor,payload,trace_id)
   values(b.project_key,r.id,b.task_key,'retry_blocked',r.idempotency_key,'director_retry_policy',jsonb_build_object('error_class',cls,'attempt',att,'retryable',p.retryable,'max_attempts',p.max_attempts),r.trace_id)
   on conflict do nothing;
   return jsonb_build_object('applied',true,'action','blocked_for_repair','class',cls,'attempt',att);
 end if;
end
$function$;