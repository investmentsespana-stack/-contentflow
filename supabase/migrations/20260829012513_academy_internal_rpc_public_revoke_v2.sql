-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

revoke execute on function public.academy_configure_web_runtime_executor_v1() from public, anon, authenticated;
grant execute on function public.academy_configure_web_runtime_executor_v1() to service_role;
revoke execute on function public.academy_plan_execution_buffer_v1(text,integer) from public, anon, authenticated;
grant execute on function public.academy_plan_execution_buffer_v1(text,integer) to service_role;
revoke execute on function public.contentflow_plan_execution_buffer_internal_v1(text,integer) from public, anon, authenticated;
grant execute on function public.contentflow_plan_execution_buffer_internal_v1(text,integer) to service_role;
