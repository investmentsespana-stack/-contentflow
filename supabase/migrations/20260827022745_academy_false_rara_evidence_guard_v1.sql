-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_guard_false_rara_evidence_v1()
returns trigger
language plpgsql
set search_path to 'public'
as $$
begin
  if coalesce(new.requirement_text,'') ilike '%RARA_ARTIFACT_REVIEW_REJECTED%'
     and coalesce(new.requirement_text,'') ilike '%class=NONE%'
     and coalesce(new.requirement_text,'') ilike '%action=COMPLETE%'
     and coalesce(new.requirement_text,'') ilike '%missing=[]%'
  then
    new.status:='obsolete';
  end if;
  return new;
end
$$;

drop trigger if exists trg_contentflow_false_rara_evidence_v1 on public.contentflow_evidence_requirements;
create trigger trg_contentflow_false_rara_evidence_v1
before insert or update on public.contentflow_evidence_requirements
for each row execute function public.contentflow_guard_false_rara_evidence_v1();
