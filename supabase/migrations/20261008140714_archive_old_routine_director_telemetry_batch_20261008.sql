-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

CREATE TABLE IF NOT EXISTS public.director_autonomy_events_archive_20261008 (LIKE public.director_autonomy_events INCLUDING DEFAULTS INCLUDING CONSTRAINTS); WITH candidates AS (SELECT id FROM public.director_autonomy_events WHERE created_at < now()-interval '30 days' AND event_type IN ('resilience_self_test','autonomy_slo_check') ORDER BY id LIMIT 2000), archived AS (INSERT INTO public.director_autonomy_events_archive_20261008 SELECT e.* FROM public.director_autonomy_events e JOIN candidates c ON c.id=e.id RETURNING id) DELETE FROM public.director_autonomy_events e USING archived a WHERE e.id=a.id;
