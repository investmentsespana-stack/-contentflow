-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

alter function public.contentflow_director_core_cycle(text,integer) set statement_timeout='30s';
alter function public.contentflow_director_core_cycle_auto(text) set statement_timeout='35s';

insert into public.director_error_memory(
  project_key,error_class,error_fingerprint,component,symptom,root_cause,correction,prevention_rule,
  evidence,occurrences,correction_successes,correction_failures,confidence,status,last_seen_at,updated_at
) values(
  'contentflow','control_plane_timeout','director_core_statement_timeout_v2','director_control_loop',
  'Auto-loop returned HTTP 200 while contentflow_director_core_cycle_auto was canceled by the authenticator 8-second statement timeout, leaving dispatchable work idle.',
  'The durable Director transaction grew beyond the generic authenticator timeout as ContentFlow accumulated reconciliation, evidence and incident history.',
  'Apply a bounded function-local statement timeout of 30s for the core and 35s for the wrapper; keep admission and concurrency caps unchanged.',
  'A healthy scheduler response is not proof of Director progress. If dispatchable>0 and core.error contains statement timeout, classify as control_plane_timeout and use the bounded Director timeout contract; never increase worker concurrency to compensate.',
  '{"authenticator_statement_timeout":"8s","director_core_timeout":"30s","director_wrapper_timeout":"35s"}'::text,
  1,0,0,0.80,'active',now(),now()
)
on conflict(project_key,error_fingerprint) do update set
  occurrences=public.director_error_memory.occurrences+1,
  root_cause=excluded.root_cause,correction=excluded.correction,prevention_rule=excluded.prevention_rule,
  evidence=excluded.evidence,status='active',last_seen_at=now(),updated_at=now();
