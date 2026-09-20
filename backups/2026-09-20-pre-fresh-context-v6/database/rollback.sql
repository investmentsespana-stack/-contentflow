-- Rollback helper for Jarvis Fresh Context v6 database additions.
-- DO NOT run automatically. Use only after explicitly deciding to revert the feature.
begin;
drop function if exists public.director_browser_action_gate(text,text,text,text,jsonb);
drop function if exists public.director_publish_context_fact(text,text,jsonb,text,text,timestamptz,timestamptz,boolean);
drop table if exists public.director_browser_action_audit;
drop table if exists public.director_context_facts;
commit;
