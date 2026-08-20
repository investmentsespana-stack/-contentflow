import test from "node:test";
import assert from "node:assert/strict";
import { chooseHealthyCandidate } from "../src/director-contract/failure-domain-router.mjs";
import { reconcileEvent } from "../src/director-contract/event-reconciler.mjs";

const candidates = [
  { id: "a", failureDomain: "model-a", healthy: true, taskClasses: ["build", "qa"], successRate: .98, latencyMs: 8000, costWeight: 2 },
  { id: "b", failureDomain: "model-b", healthy: true, taskClasses: ["build", "qa"], successRate: .97, latencyMs: 7000, costWeight: 1 },
  { id: "c", failureDomain: "model-c", healthy: true, taskClasses: ["build", "qa"], successRate: .96, latencyMs: 6000, costWeight: 1 },
];
const safe = (n) => ({ idempotencyKey:`combo-${n}`, expectedGeneration:n, leaseId:`lease-${n}`, fencingToken:n, crossProjectAccess:false, externalEffect:false });

const scenarios = [
  ["worker_timeout", "rate_limited"],
  ["lease_expired", "dependency_recovered"],
  ["state_drift", "worker_timeout"],
  ["rate_limited", "lease_expired"],
];

test("combined failures recover sequentially without human intervention or failed-domain reuse", () => {
  let recovered=0, human=0, rerouted=0;
  scenarios.forEach((pair, i) => {
    let failedDomain = i % 2 ? "model-b" : "model-a";
    pair.forEach((failure, j) => {
      const result = reconcileEvent({ id:`combo-${i}-${j}`, type:failure }, safe(i*10+j+1));
      assert.equal(result.status, "repaired");
      assert.equal(result.actor, "rara");
      const route = chooseHealthyCandidate(candidates, failedDomain, { taskClass: i%2 ? "qa" : "build" });
      assert.ok(route.selected);
      assert.notEqual(route.selected.failureDomain, failedDomain);
      failedDomain = route.selected.failureDomain;
      recovered++; rerouted++;
    });
  });
  assert.equal(recovered, 8);
  assert.equal(rerouted, 8);
  assert.equal(human, 0);
});

test("combined recovery fails closed when the second failure has no safe alternative", () => {
  const only = [{ id:"only", failureDomain:"model-a", healthy:true, taskClasses:["qa"], successRate:1, latencyMs:1, costWeight:0 }];
  const first = reconcileEvent({ type:"lease_expired" }, safe(50));
  assert.equal(first.status, "repaired");
  const route = chooseHealthyCandidate(only, "model-a", { taskClass:"qa" });
  assert.equal(route.selected, null);
  assert.equal(route.reason, "NO_HEALTHY_ALTERNATIVE");
});
