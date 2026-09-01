-- CONTENTFLOW_CHANGE_PROVENANCE_V1
-- change-class: recovery
-- lineage-recovered-from-production: true
-- original-statements-sha256: ca9c6638aa35c51f23a8dff183563581856a993b94ed451e3f88fc61eba51388

create or replace function public.contentflow_reconcile_retry_policies(p_project_key text default 'contentflow'::text, p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path to 'public'
as $function$
declare x record; n int:=0; scheduled int:=0; blocked int:=0; a jsonb; cleaned int:=0;
begin
  with obsolete as (
    select s.backlog_task_id
    from public.contentflow_retry_state s
    join public.contentflow_build_backlog b on b.id=s.backlog_task_id
    left join public.contentflow_builder_runs lr on lr.id=s.last_run_id
    where s.project_key=p_project_key
      and (
        b.status='completed'
        or coalesce(b.workflow_state,'')='superseded'
        or coalesce(b.blocked_reason,'') like 'SUPERSEDED_BY_%'
        or lr.id is null
        or lr.status not in ('failed','deferred')
        or exists(select 1 from public.contentflow_builder_runs newer where newer.backlog_task_id=s.backlog_task_id and newer.id>s.last_run_id)
        or (
          coalesce(b.epic,'') in ('evidence_capability','evidence_capability_root','capability_bootstrap')
          and b.status in ('ready','planned')
          and lr.finished_at is not null
          and b.updated_at>lr.finished_at
        )
      )
  )
  delete from public.contentflow_retry_state s using obsolete o where s.backlog_task_id=o.backlog_task_id;
  get diagnostics cleaned=row_count;

  update public.contentflow_build_backlog
     set status='deferred', next_eligible_at=null, updated_at=now()
   where project_key=p_project_key
     and (coalesce(workflow_state,'')='superseded' or coalesce(blocked_reason,'') like 'SUPERSEDED_BY_%')
     and status<>'deferred';

  for x in
    select r.id
    from public.contentflow_builder_runs r
    join public.contentflow_build_backlog b on b.id=r.backlog_task_id
    left join public.contentflow_retry_state s on s.backlog_task_id=b.id
    where r.project_key=p_project_key
      and b.status<>'completed'
      and coalesce(b.workflow_state,'')<>'superseded'
      and coalesce(b.blocked_reason,'') not like 'SUPERSEDED_BY_%'
      and r.status in ('failed','deferred') and r.finished_at is not null
      and s.last_run_id is distinct from r.id
      and r.id=(select max(z.id) from public.contentflow_builder_runs z where z.backlog_task_id=r.backlog_task_id and z.finished_at is not null)
      and not exists(
        select 1 from public.contentflow_builder_runs active
        where active.backlog_task_id=b.id and active.status in ('claimed','running','review_required','verification_required') and active.finished_at is null
      )
      and not (
        coalesce(b.epic,'') in ('evidence_capability','evidence_capability_root','capability_bootstrap')
        and b.status in ('ready','planned')
        and b.updated_at>r.finished_at
      )
    order by r.id asc limit greatest(1,least(coalesce(p_limit,100),500))
  loop
    a:=public.contentflow_apply_retry_policy(x.id); n:=n+1;
    if a->>'action'='retry_scheduled' then scheduled:=scheduled+1; elsif a->>'action'='blocked_for_repair' then blocked:=blocked+1; end if;
  end loop;
  update public.contentflow_retry_state set circuit_state='closed',circuit_open_until=null where project_key=p_project_key and circuit_state='cooldown' and next_retry_at<=now();
  return jsonb_build_object('examined',n,'scheduled',scheduled,'blocked',blocked,'obsolete_cleaned',cleaned,'superseded_guard',true,'active_run_protected',true,'bootstrap_repair_protected',true);
end
$function$;

update public.contentflow_build_backlog
set status='deferred', workflow_state='superseded', completion_phase='superseded', next_eligible_at=null, blocked_reason='SUPERSEDED_BY_academy_customer_tenancy_auth_rls_contract_v2', updated_at=now()
where project_key='agent-academy-platform-v1' and task_key='academy_customer_tenancy_auth_rls_contract_v1';

delete from public.contentflow_retry_state
where backlog_task_id=(select id from public.contentflow_build_backlog where project_key='agent-academy-platform-v1' and task_key='academy_customer_tenancy_auth_rls_contract_v1');
