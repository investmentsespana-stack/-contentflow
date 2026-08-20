import test from "node:test";
import assert from "node:assert/strict";
import { chooseHealthyCandidate, sustainedAutonomyRun } from "../src/director-contract/failure-domain-router.mjs";

const candidates = [
  { id: "worker-a", failureDomain: "model-a", healthy: true, taskClasses: ["build", "qa"], successRate: 0.98, latencyMs: 8000, costWeight: 2 },
  { id: "worker-b", failureDomain: "model-b", healthy: true, taskClasses: ["build", "qa"], successRate: 0.97, latencyMs: 7000, costWeight: 1 },
  { id: "worker-c", failureDomain: "model-c", healthy: true, taskClasses: ["build"], successRate: 0.96, latencyMs: 6000, costWeight: 1 },
  { id: "worker-dead", failureDomain: "model-dead", healthy: false, taskClasses: ["build", "qa"], successRate: 1, latencyMs: 1000, costWeight: 0 },
];

const failureTypes = ["worker_timeout", "rate_limited", "dependency_unavailable", "lease_expired", "state_drift"];

function buildStage(totalTasks) {
  const tasks = Array.from({ length: totalTasks }, (_, i) => ({
    id: `task-${totalTasks}-${i + 1}`,
    taskClass: i % 3 === 0 ? "qa" : "build",
    initialFailureDomain: i % 2 === 0 ? "model-a" : "model-b",
  }));
  const failurePlan = {};
  for (let i = 1; i < totalTasks; i += 2) {
    failurePlan[tasks[i].id] = failureTypes[Math.floor(i / 2) % failureTypes.length];
  }
  return { tasks, failurePlan };
}

function certifyStage(totalTasks) {
  const { tasks, failurePlan } = buildStage(totalTasks);
  const result = sustainedAutonomyRun({ tasks, candidates, failurePlan });
  const expectedIncidents = Math.floor(totalTasks / 2);
  assert.equal(result.totalTasks, totalTasks);
  assert.equal(result.incidents, expectedIncidents);
  assert.equal(result.autonomousRecoveries, expectedIncidents);
  assert.equal(result.humanInterventions, 0);
  assert.equal(result.completed, totalTasks);
  assert.equal(result.rerouted, expectedIncidents);
  assert.equal(result.autonomyRate, 1);
  assert.equal(result.completionRate, 1);
  const recoveries = result.timeline.filter((x) => x.status === "recovered");
  assert.equal(recoveries.length, expectedIncidents);
  assert.ok(recoveries.every((x) => x.fromDomain !== x.toDomain));
  return result;
}

test("failure-domain avoidance never routes back to the failed domain", () => {
  const route = chooseHealthyCandidate(candidates, "model-a", { taskClass: "build" });
  assert.equal(route.reason, "ALTERNATIVE_SELECTED");
  assert.ok(route.selected);
  assert.notEqual(route.selected.failureDomain, "model-a");
  assert.equal(route.selected.healthy, true);
});

test("progressive sustained autonomy escalates 24 -> 50 -> 100 only after green stage", () => {
  const stages = [24, 50, 100];
  const evidence = [];
  for (const stage of stages) {
    const result = certifyStage(stage);
    evidence.push({ tasks: stage, incidents: result.incidents, autonomyRate: result.autonomyRate, completionRate: result.completionRate });
  }
  assert.deepEqual(evidence.map((x) => x.tasks), stages);
  assert.ok(evidence.every((x) => x.autonomyRate === 1 && x.completionRate === 1));
});

test("no healthy alternative fails closed instead of reusing failed domain", () => {
  const route = chooseHealthyCandidate([
    { id: "only", failureDomain: "same", healthy: true, taskClasses: ["qa"], successRate: 1, latencyMs: 1, costWeight: 0 },
  ], "same", { taskClass: "qa" });
  assert.equal(route.selected, null);
  assert.equal(route.reason, "NO_HEALTHY_ALTERNATIVE");
});
