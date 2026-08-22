export function evaluateBudgetAdmission(input={}) {
  const configured = input.configured === true;
  const enabled = input.enabled === true;
  const monthlyBudgetUsd = Number(input.monthly_budget_usd ?? input.monthlyBudgetUsd ?? NaN);
  const maxRunCostUsd = Number(input.max_run_cost_usd ?? input.maxRunCostUsd ?? NaN);
  const spentMonthUsd = Number(input.spent_month_usd ?? input.spentMonthUsd ?? NaN);
  const validNumbers = [monthlyBudgetUsd,maxRunCostUsd,spentMonthUsd].every(Number.isFinite)
    && monthlyBudgetUsd > 0 && maxRunCostUsd >= 0 && spentMonthUsd >= 0;
  const remainingUsd = validNumbers ? Math.max(0, monthlyBudgetUsd - spentMonthUsd) : null;
  const worstCaseNextRunUsd = validNumbers ? maxRunCostUsd : null;
  const withinBudget = validNumbers && spentMonthUsd + maxRunCostUsd <= monthlyBudgetUsd;

  const blockers=[];
  if (!configured || !enabled) blockers.push('provider_budget_not_configured');
  if (configured && enabled && !validNumbers) blockers.push('provider_budget_invalid');
  if (configured && enabled && validNumbers && !withinBudget) blockers.push('provider_budget_exhausted');

  return {
    admitted:blockers.length===0,
    blockers,
    configured,
    enabled,
    monthlyBudgetUsd:validNumbers?monthlyBudgetUsd:null,
    maxRunCostUsd:validNumbers?maxRunCostUsd:null,
    spentMonthUsd:validNumbers?spentMonthUsd:null,
    remainingUsd,
    worstCaseNextRunUsd,
    withinBudget
  };
}
