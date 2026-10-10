-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

ALTER TABLE public.director_state_transition_ledger SET (autovacuum_vacuum_scale_factor = 0.03, autovacuum_analyze_scale_factor = 0.02); ALTER TABLE public.contentflow_runtime_event_ledger SET (autovacuum_vacuum_scale_factor = 0.04, autovacuum_analyze_scale_factor = 0.02); ALTER TABLE public.director_cycle_runs SET (autovacuum_vacuum_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.03); ALTER TABLE public.director_autonomy_events SET (autovacuum_vacuum_scale_factor = 0.05, autovacuum_analyze_scale_factor = 0.03);
