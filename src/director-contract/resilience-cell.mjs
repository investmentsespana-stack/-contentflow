export function createResilienceCell(config = {}) {
  const {
    id,
    taskClasses = [],
    maxConcurrency = 1,
    retryBudget = 2,
    failureThreshold = 3,
    circuitOpenMs = 30_000,
    fallbacks = [],
  } = config;
  if (!id) throw new Error("cell id required");
  if (!Number.isInteger(maxConcurrency) || maxConcurrency < 1) throw new Error("maxConcurrency must be >=1");
  if (!Number.isInteger(retryBudget) || retryBudget < 0) throw new Error("retryBudget must be >=0");
  if (!Number.isInteger(failureThreshold) || failureThreshold < 1) throw new Error("failureThreshold must be >=1");
  return {
    id,
    taskClasses: new Set(taskClasses),
    maxConcurrency,
    retryBudget,
    failureThreshold,
    circuitOpenMs,
    fallbacks: [...fallbacks],
    active: 0,
    consecutiveFailures: 0,
    circuitOpenedAt: null,
    retrySpent: 0,
    metrics: { admitted: 0, rejected: 0, successes: 0, failures: 0, degraded: 0, retries: 0 },
  };
}

export function canAdmit(cell, taskClass, now = Date.now()) {
  if (cell.taskClasses.size && !cell.taskClasses.has(taskClass)) return { ok: false, reason: "TASK_CLASS_NOT_ALLOWED" };
  if (cell.circuitOpenedAt !== null) {
    if (now - cell.circuitOpenedAt < cell.circuitOpenMs) return { ok: false, reason: "CIRCUIT_OPEN" };
    cell.circuitOpenedAt = null;
    cell.consecutiveFailures = 0;
  }
  if (cell.active >= cell.maxConcurrency) return { ok: false, reason: "BULKHEAD_FULL" };
  return { ok: true, reason: "ADMITTED" };
}

export function admit(cell, taskClass, now = Date.now()) {
  const decision = canAdmit(cell, taskClass, now);
  if (!decision.ok) {
    cell.metrics.rejected++;
    return decision;
  }
  cell.active++;
  cell.metrics.admitted++;
  return decision;
}

export function release(cell) {
  cell.active = Math.max(0, cell.active - 1);
}

export function recordSuccess(cell) {
  cell.consecutiveFailures = 0;
  cell.retrySpent = 0;
  cell.metrics.successes++;
}

export function recordFailure(cell, now = Date.now()) {
  cell.consecutiveFailures++;
  cell.metrics.failures++;
  if (cell.consecutiveFailures >= cell.failureThreshold) cell.circuitOpenedAt = now;
  return cell.circuitOpenedAt !== null;
}

export function spendRetry(cell) {
  if (cell.retrySpent >= cell.retryBudget) return { ok: false, reason: "RETRY_BUDGET_EXHAUSTED" };
  cell.retrySpent++;
  cell.metrics.retries++;
  return { ok: true, remaining: cell.retryBudget - cell.retrySpent };
}

export function chooseFallback(cell, candidates = []) {
  for (const preferred of cell.fallbacks) {
    const candidate = candidates.find((item) => item.id === preferred && item.healthy !== false);
    if (candidate) {
      cell.metrics.degraded++;
      return { selected: candidate, degraded: true };
    }
  }
  const candidate = candidates.find((item) => item.healthy !== false) ?? null;
  if (candidate) cell.metrics.degraded++;
  return { selected: candidate, degraded: Boolean(candidate) };
}

export function computeCellSlo(cell, { mttrMs = null, costPerAcceptedTask = null } = {}) {
  const attempted = cell.metrics.successes + cell.metrics.failures;
  return {
    cellId: cell.id,
    utilization: cell.maxConcurrency ? cell.active / cell.maxConcurrency : 0,
    successRate: attempted ? cell.metrics.successes / attempted : null,
    retryRate: attempted ? cell.metrics.retries / attempted : 0,
    degradedExecutions: cell.metrics.degraded,
    rejectedAdmissions: cell.metrics.rejected,
    circuitOpen: cell.circuitOpenedAt !== null,
    mttrMs,
    costPerAcceptedTask,
  };
}
