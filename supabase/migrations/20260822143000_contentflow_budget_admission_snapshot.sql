begin;

create or replace function public.contentflow_budget_admission_snapshot(
  p_project_key text default 'contentflow'
)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
with budget as (
  select monthly_budget_usd, max_run_cost_usd, is_enabled, updated_at
  from public.director_budgets
  where project_key = p_project_key
    and is_enabled = true
  order by updated_at desc, id desc
  limit 1
), usage as (
  select coalesce(sum(greatest(coalesce(actual_charged_usd,0), coalesce(estimated_cost_usd,0))),0)::numeric as spent_month_usd
  from public.nexorouter_usage_reconciliation
  where project_key = p_project_key
    and created_at >= date_trunc('month', now())
), snapshot as (
  select
    exists(select 1 from budget) as configured,
    coalesce((select is_enabled from budget),false) as enabled,
    (select monthly_budget_usd from budget) as monthly_budget_usd,
    (select max_run_cost_usd from budget) as max_run_cost_usd,
    usage.spent_month_usd,
    case when exists(select 1 from budget)
      then greatest((select monthly_budget_usd from budget) - usage.spent_month_usd,0)
      else null end as remaining_usd
  from usage
)
select jsonb_build_object(
  'configured',configured,
  'enabled',enabled,
  'monthly_budget_usd',monthly_budget_usd,
  'max_run_cost_usd',max_run_cost_usd,
  'spent_month_usd',spent_month_usd,
  'remaining_usd',remaining_usd,
  'worst_case_next_run_usd',max_run_cost_usd,
  'within_monthly_budget',case
    when configured and enabled and monthly_budget_usd > 0 and max_run_cost_usd >= 0 and spent_month_usd >= 0
      then spent_month_usd + max_run_cost_usd <= monthly_budget_usd
    else false end,
  'source','director_budgets+nexorouter_usage_reconciliation',
  'measured_at',now()
)
from snapshot;
$$;

revoke all on function public.contentflow_budget_admission_snapshot(text) from public;
grant execute on function public.contentflow_budget_admission_snapshot(text) to service_role;

commit;
