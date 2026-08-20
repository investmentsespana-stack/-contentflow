import test from "node:test";
import assert from "node:assert/strict";
import { chooseHealthyCandidate, sustainedAutonomyRun } from "../src/director-contract/failure-domain-router.mjs";

const candidates = [
  { id: "worker-a", failureDomain: "model-a", healthy: true, taskClasses: ["build", "qa"], successRate: 0.98, latencyMs: 8000, costWeight: 2 },
  { id: "worker-b", failureDomain: "model-b", healthy: true, taskClasses: ["build", "qa"], successRate: 0.97, latencyMs: 7000, costWeight: 1 },
  { id: "worker-c", failureDomain: "model-c", healthy: true, taskClasses: ["build"], successRate: 0.96, latencyMs: 6000, costWeight: 1 },
  { id: "worker-dead", failureDomain: "model-dead", healthy: false, taskClasses: ["build", "qa"], successRate: 1, latencyMs: 1000, costWeight: 0 },
];

test("failure-domain avoidance never routes back to the failed domain", () => {
  const route = chooseHealthyCandidate(candidates, "model-a", { taskClass: "build" });
  assert.equal(route.reason, "ALTERNATIVE_SELECTED");
  assert.ok(route.selected);
  assert.notEqual(route.selected.failureDomain, "model-a");
  assert.equal(route.selected.healthy, true);
});

test("sustained workload autonomously recovers interleaved known failures", () => {
  const tasks = Array.from({ length: 12 }, (_, i) => ({
    id: `task-${i + 1}`,
    taskClass: i % 3 === 0 ? "qa" : "build",
    initialFailureDomain: i % 2 === 0 ? "model-a" : "model-b",
  }));

  const failurePlan = {
    "task-2": "worker_timeout",
    "task-4": "rate_limited",
    "task-5": "dependency_unavailable",
    "task-7": "lease_expired",
    "task-9": "state_drift",
    "task-11": "worker_timeout",
  };

  const result = sustainedAutonomyRun({ tasks, candidates, failurePlan });
  assert.equal(result.totalTasks, 12);
  assert.equal(result.incidents, 6);
  assert.equal(result.autonomousRecoveries, 6);
  assert.equal(result.humanInterventions, 0);
  assert.equal(result.completed, 12);
  assert.equal(result.rerouted, 6);
  assert.equal(result.autonomyRate, 1);
  assert.equal(result.completionRate, 1);

  const recoveries = result.timeline.filter((x) => x.status === "recovered");
  assert.equal(recoveries.length, 6);
  assert.ok(recoveries.every((x) => x.fromDomain !== x.toDomain));
});

test("no healthy alternative fails closed instead of reusing failed domain", () => {
  const route = chooseHealthyCandidate([
    { id: "only", failureDomain: "same", healthy: true, taskClasses: ["qa"], successRate: 1, latencyMs: 1, costWeight: 0 },
  ], "same", { taskClass: "qa" });
  assert.equal(route.selected, null);
  assert.equal(route.reason, "NO_HEALTHY_ALTERNATIVE");
});
