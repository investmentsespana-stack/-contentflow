import test from "node:test";
import assert from "node:assert/strict";
import {
  createResilienceCell, admit, release, recordFailure, recordSuccess,
  spendRetry, chooseFallback, computeCellSlo
} from "../src/director-contract/resilience-cell.mjs";

test("bulkhead failure stays local to its cell", () => {
  const qa = createResilienceCell({ id:"qa", taskClasses:["qa"], maxConcurrency:1, failureThreshold:2 });
  const build = createResilienceCell({ id:"build", taskClasses:["build"], maxConcurrency:2, failureThreshold:2 });
  assert.equal(admit(qa,"qa").ok, true);
  assert.equal(admit(qa,"qa").reason, "BULKHEAD_FULL");
  recordFailure(qa, 1000); recordFailure(qa, 1001);
  release(qa);
  assert.equal(admit(qa,"qa",1002).reason, "CIRCUIT_OPEN");
  assert.equal(admit(build,"build",1002).ok, true);
});

test("retry budget is bounded and fail-closed", () => {
  const cell = createResilienceCell({ id:"production", retryBudget:2 });
  assert.equal(spendRetry(cell).ok, true);
  assert.equal(spendRetry(cell).ok, true);
  assert.equal(spendRetry(cell).reason, "RETRY_BUDGET_EXHAUSTED");
});

test("healthy fallback enables graceful degradation", () => {
  const cell = createResilienceCell({ id:"production", fallbacks:["secondary","reserve"] });
  const result = chooseFallback(cell,[
    { id:"primary", healthy:false },
    { id:"secondary", healthy:true },
    { id:"reserve", healthy:true }
  ]);
  assert.equal(result.selected.id, "secondary");
  assert.equal(result.degraded, true);
});

test("circuit half-open window resets after timeout and success", () => {
  const cell = createResilienceCell({ id:"tools", taskClasses:["tool"], failureThreshold:1, circuitOpenMs:10 });
  recordFailure(cell,100);
  assert.equal(admit(cell,"tool",105).reason,"CIRCUIT_OPEN");
  assert.equal(admit(cell,"tool",111).ok,true);
  recordSuccess(cell); release(cell);
  assert.equal(computeCellSlo(cell).circuitOpen,false);
});

test("SLO snapshot exposes operational signals", () => {
  const cell = createResilienceCell({ id:"qa", maxConcurrency:2 });
  admit(cell,"anything"); recordSuccess(cell); release(cell);
  chooseFallback(cell,[{ id:"fallback", healthy:true }]);
  const slo = computeCellSlo(cell,{ mttrMs:1200, costPerAcceptedTask:0.03 });
  assert.equal(slo.successRate,1);
  assert.equal(slo.degradedExecutions,1);
  assert.equal(slo.mttrMs,1200);
  assert.equal(slo.costPerAcceptedTask,0.03);
});
