-- Current production-equivalent definition captured for recovery lineage.
create or replace function public.contentflow_state_invariant_reconcile(p_project_key text)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare fixed_ready int:=0; fixed_blocked int:=0;begin
 update public.contentflow_build_backlog b
 set blocked_reason=null,next_eligible_at=coalesce(b.next_eligible_at,now()),updated_at=now()
 where b.project_key=p_project_key and b.status='ready'
   and (b.blocked_reason is not null or exists(select 1 from public.contentflow_retry_state r where r.project_key=b.project_key and r.task_key=b.task_key and r.circuit_state='open'));
 get diagnostics fixed_ready=row_count;
 update public.contentflow_retry_state r
 set circuit_state='closed',circuit_open_until=null,next_retry_at=null,updated_at=now()
 where r.project_key=p_project_key and exists(select 1 from public.contentflow_build_backlog b where b.project_key=r.project_key and b.task_key=r.task_key and b.status='ready');
 update public.contentflow_build_backlog b
 set blocked_reason=coalesce(nullif(b.blocked_reason,''),'STATE_INVARIANT_BLOCKED_UNSPECIFIED'),next_eligible_at=coalesce(b.next_eligible_at,now()+interval '7 minutes'),updated_at=now()
 where b.project_key=p_project_key and b.status='blocked' and (b.blocked_reason is null or b.next_eligible_at is null)
   and not exists(select 1 from public.director_repair_incidents i where i.project_key=b.project_key and i.status='needs_help' and i.requires_human=true);
 get diagnostics fixed_blocked=row_count;
 return jsonb_build_object('ok',true,'architecture','STATE_INVARIANT_RECONCILE_V1','fixed_ready',fixed_ready,'fixed_blocked',fixed_blocked);
end$function$;
