-- CONTENTFLOW_CHANGE_PROVENANCE_V1
-- change-class: function
-- repair-recipe: revert_quarantined_academy_dynamic_idle_planner_v1
-- migration-name: revert_quarantined_academy_dynamic_idle_planner_v1
-- incident/change: quarantine-change-id=531e09dc-b4c6-49b0-b2e1-c526b7e3b67c
-- reason: production migration 20260826221903_academy_dynamic_idle_planner_v1 was applied outside Git/provenance admission and is not accepted as desired ContentFlow state
-- intended-authority: restore_git_declared_state
-- risk: low-medium
-- rollback: re-apply only through an admitted Git PR if Academy planner integration is later explicitly approved

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
