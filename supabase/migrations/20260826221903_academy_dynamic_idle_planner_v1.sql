-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.academy_plan_execution_buffer_v1(p_project_key text default 'agent-academy-platform-v1', p_target integer default 4)
returns jsonb
language plpgsql
security definer
set search_path='public'
as $function$
declare
  v_created int:=0;
  v_dispatchable int:=0;
  v_all_prereqs boolean:=false;
begin
  if coalesce(auth.role(),'')<>'service_role' and session_user<>'postgres' then raise exception 'privileged_channel_required'; end if;
  if p_project_key<>'agent-academy-platform-v1' then
    return jsonb_build_object('ok',true,'skipped',true,'reason','academy_scope_guard','project_key',p_project_key);
  end if;

  select count(*)=5 into v_all_prereqs
  from public.contentflow_build_backlog
  where project_key=p_project_key
    and task_key in (
      'academy_brand_name_clearance_v1',
      'academy_web_experience_blueprint_v1',
      'academy_ai_instructor_avatar_blueprint_v1',
      'academy_social_warmup_plan_v1',
      'academy_growth_analytics_contract_v1'
    ) and status='completed';

  if v_all_prereqs then
    insert into public.contentflow_build_backlog(
      project_key,epic,task_key,title,description,task_type,stage,depends_on,team,status,priority,acceptance_criteria,quality_score,cost_usd,execution_lane,updated_at
    ) values
    (p_project_key,'academy_experience_wave1','academy_web_mvp_build_v1','Build Academy warm-up web MVP artifact',
     'Turn the approved Academy web experience blueprint into an implementation-ready frontend artifact for the warm-up phase. Preserve Aprendiendo Haciendo / Formacion para el trabajo, non-transactional conversion paths, accessibility, responsive behavior, and analytics hook points. Do not claim production deployment or invent repository/runtime evidence.',
     'code',3,'["academy_web_experience_blueprint_v1","academy_growth_analytics_contract_v1"]'::jsonb,'academy_dynamic_planner_v1','planned',100,
     'Implementation-ready page/component structure, responsive states, accessibility requirements, warm-up no-sales guardrails, and concrete analytics hook map; no production deployment claim.',0,0,'llm_artifact',now()),
    (p_project_key,'academy_experience_wave1','academy_ai_instructor_pilot_v1','Create AI instructor/avatar pilot package',
     'Create the first implementation-ready AI instructor/avatar pilot package for the certified AI from Zero for Business course using the approved avatar teaching blueprint. Keep the avatar renderer as an external service boundary. Include lesson-to-avatar payloads, Tutor handoff, competency evidence, failure modes and QA contract. Do not claim external avatar runtime execution.',
     'architecture',3,'["academy_ai_instructor_avatar_blueprint_v1","academy_pilot_course_ai_business_v1"]'::jsonb,'academy_dynamic_planner_v1','planned',99,
     'Pilot package maps at least one certified lesson through explanation, guided practice, lab/project, assessment and Tutor handoff with identity, safety, evidence and external-service boundary explicit.',0,0,'llm_artifact',now()),
    (p_project_key,'academy_experience_wave1','academy_social_warmup_content_batch_v1','Produce first Academy warm-up content batch',
     'Produce an implementation-ready first 14-day organic content batch for Instagram, TikTok, Facebook, YouTube and LinkedIn from the approved warm-up strategy. No pricing, enrollment, fake engagement, spam or unsupported claims. Content must be reusable across channels and traceable to the Academy methodology.',
     'general',3,'["academy_social_warmup_plan_v1","academy_web_experience_blueprint_v1"]'::jsonb,'academy_dynamic_planner_v1','planned',98,
     'Fourteen-day channel calendar with post concepts, scripts/copy, repurposing links, source/evidence requirements, CTA guardrails and measurement tags aligned to the approved growth contract.',0,0,'llm_artifact',now()),
    (p_project_key,'academy_experience_wave1','academy_growth_analytics_instrumentation_v1','Implement Academy growth analytics instrumentation spec',
     'Translate the approved growth analytics contract into an implementation-ready event instrumentation artifact for web and social attribution. Include event schemas, required/optional properties, privacy boundaries, attribution windows, deduplication, data quality checks and Director feedback inputs. Do not claim live telemetry unless runtime evidence exists.',
     'code',3,'["academy_growth_analytics_contract_v1","academy_web_experience_blueprint_v1","academy_social_warmup_plan_v1"]'::jsonb,'academy_dynamic_planner_v1','planned',97,
     'Concrete event schema and instrumentation map for approved events, privacy-safe identifiers, attribution and deduplication rules, QA checks, and Director learning inputs; no fabricated live metrics.',0,0,'llm_artifact',now()),
    (p_project_key,'academy_experience_wave1','academy_experience_integration_gate_v1','Integrate Academy web, avatar, social and analytics wave',
     'Verify that the first Academy experience implementation wave is internally coherent across web UX, instructor/avatar pilot, social warm-up content and growth analytics. Detect contradictions, missing handoffs, unsupported claims and security/privacy regressions. Produce GO/NO-GO plus exact remediation tasks if needed.',
     'architecture',4,'["academy_web_mvp_build_v1","academy_ai_instructor_pilot_v1","academy_social_warmup_content_batch_v1","academy_growth_analytics_instrumentation_v1"]'::jsonb,'academy_dynamic_planner_v1','planned',96,
     'Cross-artifact consistency gate with explicit GO/NO-GO, dependency/handoff matrix, privacy/security check, warm-up no-sales compliance, and exact remediation items for any gap.',0,0,'llm_artifact',now())
    on conflict(project_key,task_key) do nothing;
    get diagnostics v_created=row_count;
  end if;

  perform public.contentflow_normalize_dispatchability(p_project_key);
  v_dispatchable:=public.contentflow_dispatchable_count(p_project_key);
  return jsonb_build_object('ok',true,'architecture','ACADEMY_DYNAMIC_IDLE_PLANNER_V1','project_key',p_project_key,'prerequisites_complete',v_all_prereqs,'created',v_created,'dispatchable_after',v_dispatchable,'target',greatest(1,least(coalesce(p_target,4),10)));
end
$function$;

create or replace function public.contentflow_plan_execution_buffer(p_project_key text default 'contentflow', p_target integer default 10)
returns jsonb
language plpgsql
security definer
set search_path='public'
as $function$
begin
  if p_project_key='contentflow' then
    return public.contentflow_plan_execution_buffer_internal_v1(p_project_key,p_target);
  elsif p_project_key='agent-academy-platform-v1' then
    return public.academy_plan_execution_buffer_v1(p_project_key,p_target);
  else
    return jsonb_build_object('ok',true,'architecture','INFRASTRUCTURE_PLANNER_SCOPE_GUARD_V2','scope','known_project_planners_only','project_key',p_project_key,'skipped',true);
  end if;
end
$function$;
