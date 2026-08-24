-- Current production-equivalent definition captured for recovery lineage.
create or replace function public.contentflow_sync_review_work_queue()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $function$
begin
 if new.status='review_required' and (tg_op='INSERT' or old.status is distinct from new.status) then
   update public.contentflow_build_backlog
      set status='blocked',blocked_reason='REVIEW_PENDING',next_eligible_at=now()+interval '7 minutes',updated_at=now()
    where id=new.backlog_task_id and status not in ('completed','verification_required');
   insert into public.contentflow_review_work_queue(builder_run_id,task_key,state,available_at,updated_at)
   values(new.id,new.task_key,'pending',now(),now())
   on conflict(builder_run_id) do update
      set state='pending',claim_token=null,claimed_at=null,available_at=now(),last_error=null,updated_at=now();
 elsif tg_op='UPDATE' and old.status='review_required' and new.status<>'review_required' then
   update public.contentflow_review_work_queue set state='done',claim_token=null,claimed_at=null,updated_at=now() where builder_run_id=new.id;
 end if;
 return new;
end$function$;
