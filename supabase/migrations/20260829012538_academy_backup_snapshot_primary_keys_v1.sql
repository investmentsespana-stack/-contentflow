-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

alter table backup_academy_20260828.project_rows add column if not exists id bigint generated always as identity;
alter table backup_academy_20260828.related_rows add column if not exists id bigint generated always as identity;
do $$ begin
  if not exists (select 1 from pg_constraint where conrelid='backup_academy_20260828.project_rows'::regclass and contype='p') then
    alter table backup_academy_20260828.project_rows add primary key(id);
  end if;
  if not exists (select 1 from pg_constraint where conrelid='backup_academy_20260828.related_rows'::regclass and contype='p') then
    alter table backup_academy_20260828.related_rows add primary key(id);
  end if;
end $$;
