-- ContentFlow sanitized recovery baseline
-- 2026-08-16

-- Fixed concurrency policy must remain 2 until explicitly changed.
update public.director_canary_policy set bootstrap_parallelism=2,stable_parallelism=2,updated_at=now() where id=1;
update public.director_control_policy set desired_running=2,updated_at=now() where project_key='contentflow';
update public.contentflow_capacity_state set auto_scale=false,updated_at=now() where id=1;

-- Remove legacy autoscaling scheduler.
select cron.unschedule(jobid) from cron.job where jobname='contentflow_capacity_autoscale_15m';

-- Remove legacy competing completion trigger.
drop trigger if exists trg_backlog_review_gate on public.contentflow_build_backlog;

-- Quarantine legacy write paths.
revoke execute on function public.internal_builder_finalize(bigint,text,text,numeric,numeric,text,text,boolean) from public,anon,authenticated,service_role;
revoke execute on function public.internal_builder_approve_review(bigint) from public,anon,authenticated,service_role;
revoke execute on function public.contentflow_builder_heartbeat(bigint,integer) from public,anon,authenticated,service_role;
revoke execute on function public.internal_builder_recover_stale_claims(integer) from public,anon,authenticated,service_role;
revoke execute on function public.rara_apply_review_decision(bigint,boolean,text) from public,anon,authenticated,service_role;

-- Canonical dependency graph sanitation.
create or replace function public.contentflow_sanitize_dependency_graph(p_project_key text default 'contentflow') returns jsonb language plpgsql security definer set search_path=public as $$
declare r record; cleaned int:=0; self_removed int:=0; dup_removed int:=0; old_n int; new_n int; self_n int;
begin
 if coalesce(auth.role(),'')<>'service_role' then raise exception 'service_role_required'; end if;
 for r in select id,task_key,depends_on from public.contentflow_build_backlog where project_key=p_project_key loop
   old_n:=jsonb_array_length(coalesce(r.depends_on,'[]'::jsonb));
   select count(*) into self_n from jsonb_array_elements_text(coalesce(r.depends_on,'[]'::jsonb)) d(v) where d.v=r.task_key;
   with vals as (select distinct d.v from jsonb_array_elements_text(coalesce(r.depends_on,'[]'::jsonb)) d(v) where d.v<>r.task_key and exists(select 1 from public.contentflow_build_backlog x where x.project_key=p_project_key and x.task_key=d.v))
   select coalesce(jsonb_agg(v order by v),'[]'::jsonb),count(*) into r.depends_on,new_n from vals;
   if old_n<>new_n then
     update public.contentflow_build_backlog set depends_on=r.depends_on,updated_at=now() where id=r.id;
     cleaned:=cleaned+1; self_removed:=self_removed+self_n; dup_removed:=dup_removed+greatest(0,old_n-new_n-self_n);
   end if;
 end loop;
 return jsonb_build_object('tasks_cleaned',cleaned,'self_dependencies_removed',self_removed,'duplicate_or_missing_removed',dup_removed);
end $$;

create or replace function public.contentflow_guard_dependency_graph() returns trigger language plpgsql set search_path=public as $$
declare n int; d int;
begin
 if new.project_key='contentflow' then
   if exists(select 1 from jsonb_array_elements_text(coalesce(new.depends_on,'[]'::jsonb)) x(v) where x.v=new.task_key) then raise exception 'dependency_self_reference_forbidden'; end if;
   select count(*),count(distinct v) into n,d from jsonb_array_elements_text(coalesce(new.depends_on,'[]'::jsonb)) x(v);
   if n<>d then raise exception 'duplicate_dependencies_forbidden'; end if;
 end if;
 return new;
end $$;

drop trigger if exists trg_contentflow_guard_dependency_graph on public.contentflow_build_backlog;
create trigger trg_contentflow_guard_dependency_graph before insert or update of task_key,depends_on on public.contentflow_build_backlog for each row execute function public.contentflow_guard_dependency_graph();
