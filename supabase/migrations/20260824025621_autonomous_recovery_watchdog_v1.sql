-- Current production-equivalent definition captured for recovery lineage.
create or replace function public.contentflow_recovery_watchdog_v1()
returns jsonb
language plpgsql
security definer
set search_path to 'public','net'
as $function$
declare rec record; recovered int:=0; owner_wait int:=0; action jsonb; req bigint;
begin
 for rec in
   select b.id backlog_id,b.project_key,b.task_key,b.updated_at,rs.last_run_id,r.error,r.finished_at,
          public.contentflow_classify_run_error(r.error) err_class,
          public.rara_classify_rejection(r.error) rara_class
   from public.contentflow_build_backlog b
   join public.contentflow_retry_state rs on rs.backlog_task_id=b.id
   left join public.contentflow_builder_runs r on r.id=rs.last_run_id
   where b.status='blocked' and b.blocked_reason='CIRCUIT_OPEN' and rs.circuit_state='open'
     and coalesce(r.finished_at,b.updated_at) <= now()-interval '7 minutes'
     and not exists(select 1 from public.contentflow_builder_runs ar where ar.backlog_task_id=b.id and ar.status in ('claimed','running','review_required','verification_required') and ar.finished_at is null)
 loop
   if rec.rara_class='owner_required' then
     owner_wait:=owner_wait+1;
     update public.director_repair_incidents set requires_human=true,updated_at=now() where project_key=rec.project_key and status in ('open','analyzing','needs_help') and coalesce(requires_human,false)=false;
   elsif coalesce(rec.error,'') ilike '%RARA_REVIEW_REJECTED%' then
     action:=public.rara_learn_and_replan_rejection(rec.last_run_id,rec.error);
     if coalesce((action->>'ok')::boolean,false) then recovered:=recovered+1; end if;
   elsif rec.err_class in ('capacity','judge','provider','timeout','state_recovery') then
     update public.contentflow_retry_state set circuit_state='closed',attempt_count=0,next_retry_at=now(),circuit_open_until=null,updated_at=now() where backlog_task_id=rec.backlog_id;
     update public.contentflow_build_backlog set status='ready',blocked_reason=null,next_eligible_at=now(),selected_model=null,updated_at=now() where id=rec.backlog_id;
     recovered:=recovered+1;
   else
     update public.contentflow_retry_state set circuit_state='closed',attempt_count=0,next_retry_at=now(),circuit_open_until=null,updated_at=now() where backlog_task_id=rec.backlog_id;
     update public.contentflow_build_backlog set status='ready',blocked_reason=null,next_eligible_at=now(),selected_model=null,description=coalesce(description,'')||E'\n\n[AUTO-WATCHDOG] Previous recoverable failure stalled >=7m. Re-evaluate root cause before resubmission; do not repeat prior rejected structure.',updated_at=now() where id=rec.backlog_id;
     recovered:=recovered+1;
   end if;
 end loop;
 if recovered>0 then
   select net.http_post(url:='https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/contentflow-auto-loop',headers:='{"Content-Type":"application/json"}'::jsonb,body:='{}'::jsonb,timeout_milliseconds:=30000) into req;
 end if;
 return jsonb_build_object('architecture','AUTONOMOUS_RECOVERY_WATCHDOG_V1_7MIN','recovered',recovered,'owner_wait',owner_wait,'wake_request_id',req);
end$function$;

do $block$
begin
 if not exists(select 1 from cron.job where jobname='contentflow_recovery_watchdog_1m') then
   perform cron.schedule('contentflow_recovery_watchdog_1m','* * * * *','select public.contentflow_recovery_watchdog_v1();');
 end if;
end
$block$;
