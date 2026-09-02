-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

DROP FUNCTION IF EXISTS public.academy_plan_execution_buffer_v1(text, integer);

CREATE OR REPLACE FUNCTION public.contentflow_plan_execution_buffer(
  p_project_key text DEFAULT 'contentflow'::text,
  p_target integer DEFAULT 10
) RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public'
AS $function$
begin
  if p_project_key<>'contentflow' then
    return jsonb_build_object(
      'ok',true,
      'architecture','INFRASTRUCTURE_PLANNER_SCOPE_GUARD_V1',
      'scope','contentflow_only',
      'project_key',p_project_key,
      'skipped',true
    );
  end if;
  return public.contentflow_plan_execution_buffer_internal_v1(p_project_key,p_target);
end
$function$;
