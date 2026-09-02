-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

do $$ begin perform cron.unschedule('academy-direct-tool-kick-5m'); exception when others then null; end $$; select cron.schedule('academy-direct-tool-kick-5m','*/5 * * * *',$$select net.http_post(url:='https://koqpyfvnprmirqviafzq.supabase.co/functions/v1/contentflow-direct-tool-kick-academy', headers:='{"Content-Type":"application/json"}'::jsonb, body:='{}'::jsonb, timeout_milliseconds:=30000);$$);
