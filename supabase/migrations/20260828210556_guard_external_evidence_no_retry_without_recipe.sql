-- Reconciled from supabase_migrations.schema_migrations by recovery automation.
-- Source: canonical production migration history; no credentials are emitted.

create or replace function public.contentflow_tool_execution_capability_ready(p_project_key text, p_task_key text)
returns boolean
language plpgsql
stable
security definer
set search_path to 'public'
as $function$
declare
  b record;
  er record;
  prereq text;
  producer boolean:=false;
  recipe jsonb;
  has_recipe boolean:=false;
begin
  select id,epic,completion_phase,execution_lane,coalesce(workflow_contract,'{}'::jsonb) workflow_contract
    into b
  from public.contentflow_build_backlog
  where project_key=p_project_key and task_key=p_task_key
  order by id desc limit 1;
  if not found then return false; end if;

  if coalesce(b.epic,'')='evidence_first' or coalesce(b.completion_phase,'')='evidence_required' or coalesce(b.execution_lane,'')='evidence_producer' then
    select * into er
    from public.contentflow_evidence_requirements
    where project_key=p_project_key and evidence_task_key=p_task_key
    order by id desc limit 1;
    if not found then return false; end if;

    if public.contentflow_evidence_verifier_preflight(p_project_key,p_task_key) then
      return true;
    end if;

    select exists(
      select 1
      from public.contentflow_evidence_producer_recipes r
      where r.project_key=p_project_key
        and r.evidence_task_key=p_task_key
        and r.enabled=true
    ) into has_recipe;

    if coalesce((b.workflow_contract->>'no_retry_without_new_evidence')::boolean,false)
       and not has_recipe then
      return false;
    end if;

    prereq:=public.contentflow_evidence_prerequisite_class(er.requirement_class,er.requirement_text);
    select coalesce(producer_available,false) into producer
    from public.contentflow_evidence_capability_registry
    where prerequisite=prereq;
    return coalesce(producer,false);
  end if;

  if coalesce(b.execution_lane,'')='tool_executor' then
    recipe:=b.workflow_contract->'execution_recipe';
    return recipe is not null
       and jsonb_typeof(recipe)='object'
       and coalesce(recipe->>'handler','') in ('database_rpc','edge_function');
  end if;

  return false;
end;
$function$;
