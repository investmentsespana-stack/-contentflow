create or replace function public.rara_claim_review_v2(p_project_key text default null)
returns table(out_builder_run_id bigint,out_task_key text,out_claim_token text)
language plpgsql security definer set search_path=public as $$
declare v_id bigint; v_task text; v_token text:=gen_random_uuid()::text;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 update public.contentflow_review_work_queue q
 set state='pending',claim_token=null,claimed_at=null,available_at=now(),last_error='stale_review_claim_recovered_v2',updated_at=now()
 where q.state='claimed' and q.claimed_at<now()-interval '3 minutes'
   and exists(select 1 from public.contentflow_builder_runs r where r.id=q.builder_run_id and r.status='review_required');
 select q.builder_run_id,q.task_key into v_id,v_task
 from public.contentflow_review_work_queue q
 join public.contentflow_builder_runs r on r.id=q.builder_run_id
 where q.state='pending' and q.available_at<=now() and r.status='review_required'
   and (p_project_key is null or r.project_key=p_project_key)
 order by q.updated_at,q.builder_run_id
 for update of q skip locked limit 1;
 if v_id is null then return; end if;
 update public.contentflow_review_work_queue q
 set state='claimed',claim_token=v_token,claimed_at=now(),attempts=q.attempts+1,updated_at=now()
 where q.builder_run_id=v_id and q.state='pending';
 if not found then return; end if;
 return query select v_id,v_task,v_token;
end $$;
revoke all on function public.rara_claim_review_v2(text) from public,anon,authenticated;
grant execute on function public.rara_claim_review_v2(text) to service_role;
