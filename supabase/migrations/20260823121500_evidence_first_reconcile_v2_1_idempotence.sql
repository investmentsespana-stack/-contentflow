-- V2.1 fixes a V2 regression where an existing requirement could retain its
-- original evidence_task_key while reconciliation created/attached a newly
-- computed harness key. That produced orphan evidence dependencies on every
-- replay. Existing active requirements now own their evidence_task_key.

create or replace function public.contentflow_evidence_first_reconcile(p_project_key text default 'contentflow', p_limit integer default 50)
returns jsonb language plpgsql security definer set search_path='public'
as $function$
declare
  x record;
  v_fp text;
  v_cls text;
  v_evidence_key text;
  v_existing_evidence_key text;
  v_created int:=0;
  v_held int:=0;
  v_verified int:=0;
  v_reopened int:=0;
  v_reused int:=0;
  v_existing bigint;
  v_existing_status text;
  v_dep jsonb;
  v_new_dep jsonb;
begin
  if coalesce(auth.role(),'') <> 'service_role' and session_user <> 'postgres' then
    raise exception 'privileged_channel_required';
  end if;

  for x in
    select r.id run_id,r.backlog_task_id,r.task_key,r.error,r.created_at,
           b.title,b.depends_on,b.status,b.completion_phase
    from public.contentflow_builder_runs r
    join public.contentflow_build_backlog b on b.id=r.backlog_task_id
    where r.project_key=p_project_key
      and b.status<>'completed'
      and b.task_key not like 'evidence_%'
      and r.status in ('failed','deferred')
      and r.finished_at is not null
      and (
        coalesce(r.error,'') ilike '%RARA_REVIEW_REJECTED%'
        or coalesce(r.error,'') ilike '%NEEDS_EVIDENCE%'
        or coalesce(r.error,'') ilike '%missing evidence%'
        or coalesce(r.error,'') ilike '%no persisted runtime evidence%'
      )
      and r.id=(select max(z.id) from public.contentflow_builder_runs z where z.backlog_task_id=r.backlog_task_id and z.finished_at is not null)
    order by r.id asc
    limit greatest(1,least(coalesce(p_limit,50),200))
  loop
    v_cls:=public.contentflow_evidence_requirement_class(x.error);
    v_fp:=md5(lower(x.task_key)||'|'||v_cls);
    v_evidence_key:='evidence_'||left(regexp_replace(x.task_key,'[^a-zA-Z0-9_]+','','g'),70)||'_'||left(v_fp,10);
    v_existing:=null;
    v_existing_status:=null;
    v_existing_evidence_key:=null;

    select er.id,er.status,er.evidence_task_key
      into v_existing,v_existing_status,v_existing_evidence_key
      from public.contentflow_evidence_requirements er
     where er.project_key=p_project_key
       and er.backlog_task_id=x.backlog_task_id
       and er.requirement_class=v_cls
       and er.status<>'obsolete'
     order by case when er.status='verified' then 0 else 1 end,er.id
     limit 1;

    if v_existing is not null and v_existing_status='verified' then
      v_reused:=v_reused+1;
      continue;
    end if;

    if v_existing is not null then
      -- Critical V2.1 invariant: the already-persisted requirement owns the
      -- harness identity. Never attach a different freshly computed key.
      if coalesce(v_existing_evidence_key,'')<>'' then
        v_evidence_key:=v_existing_evidence_key;
      end if;

      update public.contentflow_evidence_requirements
         set requirement_fingerprint=v_fp,
             requirement_text=left(coalesce(x.error,'NEEDS_EVIDENCE'),6000),
             evidence_task_key=v_evidence_key,
             updated_at=now()
       where id=v_existing
         and (
           requirement_fingerprint is distinct from v_fp
           or requirement_text is distinct from left(coalesce(x.error,'NEEDS_EVIDENCE'),6000)
           or evidence_task_key is distinct from v_evidence_key
         );
    else
      insert into public.contentflow_evidence_requirements(
        project_key,backlog_task_id,source_run_id,task_key,requirement_class,
        requirement_fingerprint,requirement_text,evidence_task_key,status,updated_at
      ) values(
        p_project_key,x.backlog_task_id,x.run_id,x.task_key,v_cls,v_fp,
        left(coalesce(x.error,'NEEDS_EVIDENCE'),6000),v_evidence_key,'task_created',now()
      ) returning id into v_existing;
    end if;

    if not exists(
      select 1 from public.contentflow_build_backlog e
      where e.project_key=p_project_key and e.task_key=v_evidence_key
    ) then
      insert into public.contentflow_build_backlog(
        project_key,epic,task_key,title,description,task_type,stage,depends_on,
        team,status,priority,acceptance_criteria,quality_score,next_eligible_at,
        completion_phase,execution_lane
      ) values(
        p_project_key,'evidence_first',v_evidence_key,
        'Evidence harness: '||left(coalesce(x.title,x.task_key),180),
        'Produce REAL, persisted, correlated evidence for source task '||x.task_key||
          ' and source builder_run_id='||x.run_id||'. Requirement class='||v_cls||
          '. Do not fabricate evidence.',
        'code',1,coalesce(x.depends_on,'[]'::jsonb),'evidence-first','blocked',100,
        'Evidence must be produced by an actual deterministic test, static analysis, integration, persisted runtime record, or externally verifiable artifact; generic prose/placeholders do not satisfy acceptance.',
        0,now(),'evidence_required','tool_executor'
      );
      v_created:=v_created+1;
    end if;

    select coalesce(depends_on,'[]'::jsonb)
      into v_dep
      from public.contentflow_build_backlog
     where id=x.backlog_task_id
     for update;

    v_new_dep:=v_dep;
    if not (v_new_dep ? v_evidence_key) then
      v_new_dep:=v_new_dep||to_jsonb(v_evidence_key);
    end if;

    update public.contentflow_build_backlog
       set depends_on=v_new_dep,
           status='blocked',
           selected_model=null,
           next_eligible_at=null,
           completion_phase='waiting_for_evidence',
           updated_at=now()
     where id=x.backlog_task_id
       and status<>'completed'
       and (
         depends_on is distinct from v_new_dep
         or status<>'blocked'
         or completion_phase<>'waiting_for_evidence'
       );
    if found then v_held:=v_held+1; end if;

    delete from public.contentflow_retry_state where backlog_task_id=x.backlog_task_id;
  end loop;

  update public.contentflow_evidence_requirements er
     set status='verified',verified_at=now(),updated_at=now(),
         evidence_ref=jsonb_build_object(
           'evidence_task_key',er.evidence_task_key,
           'evidence_task_id',e.id,
           'source_run_id',er.source_run_id,
           'runtime_evidence',coalesce(e.runtime_evidence,'{}'::jsonb)
         )
    from public.contentflow_build_backlog e
   where er.project_key=p_project_key
     and er.status='task_created'
     and e.project_key=er.project_key
     and e.task_key=er.evidence_task_key
     and e.status='completed'
     and coalesce(e.runtime_verified,false)=true
     and coalesce(e.runtime_evidence,'{}'::jsonb)<>'{}'::jsonb;
  get diagnostics v_verified=row_count;

  perform public.contentflow_gc_evidence_dependencies(p_project_key);
  select (public.contentflow_reconcile_ready_after_evidence(p_project_key)->>'reopened')::int
    into v_reopened;

  return jsonb_build_object(
    'architecture','EVIDENCE_FIRST_EXECUTION_V2_1',
    'requirements_created',v_created,
    'verified_requirements_reused',v_reused,
    'originals_held',v_held,
    'requirements_verified',v_verified,
    'originals_reopened',coalesce(v_reopened,0)
  );
end
$function$;

revoke all on function public.contentflow_evidence_first_reconcile(text,integer)
  from public,anon,authenticated;
grant execute on function public.contentflow_evidence_first_reconcile(text,integer)
  to service_role;
