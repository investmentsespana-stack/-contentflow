-- Tenant/RLS Security Admission Gate V1
-- Non-disruptive by design: this does NOT enable RLS or revoke grants on legacy
-- control-plane tables. It blocks customer-facing reuse/promotion until a table
-- has an explicitly approved exposure class and satisfies isolation checks.

create table if not exists public.contentflow_tenant_security_targets(
  table_name text primary key,
  exposure_class text not null default 'internal_only' check (exposure_class in ('internal_only','customer_candidate','customer_approved')),
  required_rls boolean not null default true,
  notes text,
  updated_at timestamptz not null default now()
);

alter table public.contentflow_tenant_security_targets enable row level security;
revoke all on table public.contentflow_tenant_security_targets from public,anon,authenticated;
grant select,insert,update,delete on table public.contentflow_tenant_security_targets to service_role;

insert into public.contentflow_tenant_security_targets(table_name,exposure_class,required_rls,notes) values
('contentflow_workflow_e2e_state','internal_only',true,'Internal workflow certification state; direct customer reuse prohibited until tenant design and negative tests pass.'),
('director_recovery_learning_memory','internal_only',true,'Director/RARA recovery memory; privileged control-plane data.'),
('contentflow_capability_certifications','internal_only',true,'Capability certification ledger; privileged execution-control data.'),
('contentflow_primary_source_evidence','internal_only',true,'Primary-source evidence ledger; tenant boundary must be explicit before reuse.'),
('director_project_task_scope','internal_only',true,'Director authority/scope table; must never be implicitly exposed to tenants.'),
('contentflow_durable_task_stages','internal_only',true,'Durable execution checkpoints; internal orchestration state.')
on conflict(table_name) do update set
  notes=excluded.notes,
  required_rls=excluded.required_rls,
  updated_at=now();

create or replace function public.contentflow_tenant_security_admission_v1(p_scope text default 'customer_facing')
returns jsonb
language plpgsql
stable
security definer
set search_path='public','pg_temp'
as $function$
declare
  r record;
  v_rel oid;
  v_rls boolean;
  v_force boolean;
  v_anon_grants int;
  v_auth_write int;
  v_policy_count int;
  v_blockers jsonb:='[]'::jsonb;
  v_tables jsonb:='[]'::jsonb;
  v_scope text:=lower(coalesce(nullif(p_scope,''),'customer_facing'));
  v_ok boolean:=true;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then
    raise exception 'service_role_required';
  end if;
  if v_scope not in ('customer_facing','internal_control') then
    raise exception 'unsupported_security_admission_scope:%',v_scope;
  end if;

  for r in select * from public.contentflow_tenant_security_targets order by table_name loop
    select c.oid,c.relrowsecurity,c.relforcerowsecurity into v_rel,v_rls,v_force
    from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname=r.table_name and c.relkind in ('r','p');

    if v_rel is null then
      v_ok:=false;
      v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('table',r.table_name,'reason','table_missing'));
      v_tables:=v_tables||jsonb_build_array(jsonb_build_object('table',r.table_name,'exists',false));
      continue;
    end if;

    select count(*) into v_anon_grants
    from information_schema.role_table_grants g
    where g.table_schema='public' and g.table_name=r.table_name and g.grantee='anon';

    select count(*) into v_auth_write
    from information_schema.role_table_grants g
    where g.table_schema='public' and g.table_name=r.table_name and g.grantee='authenticated'
      and g.privilege_type in ('INSERT','UPDATE','DELETE','TRUNCATE','TRIGGER','REFERENCES');

    select count(*) into v_policy_count from pg_policy p where p.polrelid=v_rel;

    if v_scope='customer_facing' then
      if r.exposure_class='internal_only' then
        v_ok:=false;
        v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('table',r.table_name,'reason','internal_only_not_promotable'));
      end if;
      if r.required_rls and not coalesce(v_rls,false) then
        v_ok:=false;
        v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('table',r.table_name,'reason','rls_disabled'));
      end if;
      if v_anon_grants>0 then
        v_ok:=false;
        v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('table',r.table_name,'reason','anon_table_grants_present','count',v_anon_grants));
      end if;
      if v_auth_write>0 then
        v_ok:=false;
        v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('table',r.table_name,'reason','authenticated_write_grants_present','count',v_auth_write));
      end if;
      if r.exposure_class in ('customer_candidate','customer_approved') and r.required_rls and v_policy_count=0 then
        v_ok:=false;
        v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('table',r.table_name,'reason','rls_policy_missing'));
      end if;
    end if;

    v_tables:=v_tables||jsonb_build_array(jsonb_build_object(
      'table',r.table_name,
      'exists',true,
      'exposure_class',r.exposure_class,
      'rls_enabled',coalesce(v_rls,false),
      'rls_forced',coalesce(v_force,false),
      'anon_grants',v_anon_grants,
      'authenticated_write_grants',v_auth_write,
      'policy_count',v_policy_count
    ));
  end loop;

  return jsonb_build_object(
    'architecture','TENANT_RLS_SECURITY_ADMISSION_V1',
    'scope',v_scope,
    'admitted',v_ok,
    'fail_closed',true,
    'tables',v_tables,
    'blockers',v_blockers,
    'evaluated_at',now()
  );
end $function$;

create or replace function public.contentflow_assert_tenant_security_admission_v1(p_scope text default 'customer_facing')
returns jsonb
language plpgsql
security definer
set search_path='public','pg_temp'
as $function$
declare v jsonb;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then
    raise exception 'service_role_required';
  end if;
  v:=public.contentflow_tenant_security_admission_v1(p_scope);
  if not coalesce((v->>'admitted')::boolean,false) then
    raise exception 'TENANT_SECURITY_ADMISSION_DENIED:%',v->'blockers';
  end if;
  return v;
end $function$;

revoke all on function public.contentflow_tenant_security_admission_v1(text) from public,anon,authenticated;
grant execute on function public.contentflow_tenant_security_admission_v1(text) to service_role;
revoke all on function public.contentflow_assert_tenant_security_admission_v1(text) from public,anon,authenticated;
grant execute on function public.contentflow_assert_tenant_security_admission_v1(text) to service_role;
