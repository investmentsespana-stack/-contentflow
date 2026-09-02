-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

do $patch$
declare
  v_def text;
  v_new text;
begin
  select pg_get_functiondef('public.internal_builder_dispatch()'::regprocedure) into v_def;

  v_new := replace(
    v_def,
    'BUILDER_RUN_ID: %s',
    'CONTRATO DE EJECUCION CANONICO: %s | EVIDENCIA EXTERNA VERIFICADA: %s | BUILDER_RUN_ID: %s'
  );

  if v_new = v_def then
    raise exception 'builder_prompt_contract_injection_not_applied';
  end if;

  execute v_new;
end
$patch$;
