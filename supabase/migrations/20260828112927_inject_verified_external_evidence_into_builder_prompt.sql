-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_verified_external_evidence_context(p_project_key text, p_task_key text)
returns text
language sql
stable
security invoker
set search_path to 'public'
as $fn$
  select string_agg(
    format('type=%s | status=%s | verified=%s | source=%s | evidence=%s',
      e.evidence_type,
      e.status,
      e.verified,
      coalesce(e.source,''),
      left(coalesce(e.evidence::text,'{}'),2000)
    ),
    E'\n---\n'
    order by e.created_at desc, e.id desc
  )
  from public.director_external_evidence e
  where e.project_key=p_project_key
    and e.task_key=p_task_key
    and e.verified=true
    and e.status='pass';
$fn$;

do $patch$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef('public.internal_builder_dispatch()'::regprocedure) into v_def;

  v_new := replace(
    v_def,
    'CRITERIO DE ACEPTACION: %s\\n\\nBUILDER_RUN_ID: %s',
    'CRITERIO DE ACEPTACION: %s\\n\\nCONTRATO DE EJECUCION CANONICO: %s\\n\\nEVIDENCIA EXTERNA VERIFICADA: %s\\n\\nBUILDER_RUN_ID: %s'
  );

  v_new := replace(
    v_new,
    'coalesce(v_task.acceptance_criteria,''''),v_run_id,coalesce(v_dep_context,''NO_DEPENDENCIES''),coalesce(v_runtime_context,''NO_DIRECT_RUNTIME_SNAPSHOT''));',
    'coalesce(v_task.acceptance_criteria,''''),coalesce(v_task.workflow_contract::text,''{}''),coalesce(public.contentflow_verified_external_evidence_context(v_task.project_key,v_task.task_key),''NO_VERIFIED_EXTERNAL_EVIDENCE''),v_run_id,coalesce(v_dep_context,''NO_DEPENDENCIES''),coalesce(v_runtime_context,''NO_DIRECT_RUNTIME_SNAPSHOT''));'
  );

  if v_new = v_def then
    raise exception 'internal_builder_dispatch_patch_not_applied';
  end if;

  execute v_new;
end
$patch$;
