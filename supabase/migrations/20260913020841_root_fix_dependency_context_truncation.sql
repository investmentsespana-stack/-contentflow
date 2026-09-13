-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

do $$
declare
  v_def text;
  v_old text := 'left(coalesce(d.result,'''') ,3000)';
begin
  select pg_get_functiondef(p.oid)
    into v_def
  from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='internal_builder_dispatch'
  limit 1;

  if v_def is null then
    raise exception 'internal_builder_dispatch_not_found';
  end if;

  -- Exact source currently uses left(coalesce(d.result,''),3000). Replace only that expression.
  v_def := replace(
    v_def,
    'left(coalesce(d.result,'''') ,3000)',
    'case when length(coalesce(d.result,'''')) <= 9000 then coalesce(d.result,'''') else left(coalesce(d.result,''''),3500)||E''\\n...[DEPENDENCY_CONTEXT_TRUNCATED: DO NOT RECONSTRUCT SOURCE; USE ONLY VISIBLE CONTRACT AND VERIFIED RUNTIME EVIDENCE]...\\n''||right(coalesce(d.result,''''),3500) end'
  );

  if position('left(coalesce(d.result,''''),3000)' in v_def) > 0 then
    v_def := replace(
      v_def,
      'left(coalesce(d.result,''''),3000)',
      'case when length(coalesce(d.result,'''')) <= 9000 then coalesce(d.result,'''') else left(coalesce(d.result,''''),3500)||E''\\n...[DEPENDENCY_CONTEXT_TRUNCATED: DO NOT RECONSTRUCT SOURCE; USE ONLY VISIBLE CONTRACT AND VERIFIED RUNTIME EVIDENCE]...\\n''||right(coalesce(d.result,''''),3500) end'
    );
  end if;

  if position('DEPENDENCY_CONTEXT_TRUNCATED' in v_def)=0 then
    raise exception 'dependency_context_patch_not_applied';
  end if;

  execute v_def;
end $$;
