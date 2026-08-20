import test from "node:test";
import assert from "node:assert/strict";
import { autonomyOutcome, reconcileEvent } from "../src/director-contract/event-reconciler.mjs";

const safe = (n = 1) => ({
  idempotencyKey: `idem-${n}`,
  expectedGeneration: n,
  leaseId: `lease-${n}`,
  fencingToken: n,
  crossProjectAccess: false,
  externalEffect: false,
});

test("known failure is repaired by RARA without human/director intervention", () => {
  const result = reconcileEvent({ id: "e1", type: "lease_expired" }, safe(2));
  assert.equal(result.status, "repaired");
  assert.equal(result.actor, "rara");
  assert.equal(result.action, "reclaim_and_reassign");
  assert.equal(result.continueWork, true);
});

test("dependency recovery resumes blocked work automatically", () => {
  const result = reconcileEvent({ id: "e2", type: "dependency_recovered" }, safe(3));
  assert.equal(result.status, "repaired");
  assert.equal(result.action, "resume_blocked_work");
});

test("RARA cannot repair without fencing/generation/idempotency", () => {
  const result = reconcileEvent({ id: "e3", type: "worker_timeout" }, {});
  assert.equal(result.status, "blocked");
  assert.equal(result.reason, "RARA_GUARDRAIL_BLOCK");
  assert.equal(result.continueWork, undefined);
});

test("RARA cannot cross project or cause external effects", () => {
  assert.equal(reconcileEvent({ type: "state_drift" }, { ...safe(4), crossProjectAccess: true }).status, "blocked");
  assert.equal(reconcileEvent({ type: "state_drift" }, { ...safe(4), externalEffect: true }).status, "blocked");
});

test("unknown event fails closed and routes to Director diagnosis", () => {
  const result = reconcileEvent({ id: "e4", type: "novel_failure" }, safe(5));
  assert.equal(result.status, "diagnosis_required");
  assert.equal(result.actor, "director");
  assert.equal(result.action, "fail_closed_and_diagnose");
  assert.equal(result.continueWork, false);
});

test("fault sequence recovers known incidents autonomously and continues", () => {
  const events = [
    { id: "f1", type: "lease_expired" },
    { id: "f2", type: "rate_limited" },
    { id: "f3", type: "dependency_recovered" },
    { id: "f4", type: "state_drift" },
  ];
  const result = autonomyOutcome(events, (_event, index) => safe(index + 1));
  assert.equal(result.repaired, 4);
  assert.equal(result.total, 4);
  assert.equal(result.autonomyRate, 1);
  assert.ok(result.results.every((x) => x.actor === "rara" && x.continueWork === true));
});
