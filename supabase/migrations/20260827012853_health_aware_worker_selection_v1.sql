-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

do $$
declare
  f text;
  old_fragment text := $old$where q.status='ready'
   and not exists(select 1 from public.contentflow_builder_runs ar where ar.selected_model=q.model_id and ar.status in ('claimed','running') and ar.finished_at is null)$old$;
  new_fragment text := $new$where q.status='ready'
   and not exists(select 1 from public.contentflow_builder_runs ar where ar.selected_model=q.model_id and ar.status in ('claimed','running') and ar.finished_at is null)
   and not exists(select 1 from public.contentflow_nexo_request_metrics m where m.model=q.model_id and m.created_at>now()-interval '15 minutes' and m.status_code=404)$new$;
begin
  select pg_get_functiondef(p.oid) into f
  from pg_proc p join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname='internal_builder_dispatch'
  limit 1;
  if position(old_fragment in f)=0 then
    raise exception 'target_fragment_not_found';
  end if;
  f := replace(f, old_fragment, new_fragment);
  execute f;
end $$;
