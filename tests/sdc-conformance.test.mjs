import test from "node:test";
import assert from "node:assert/strict";
import { validateObserveContract } from "../src/director-contract/conformance.mjs";

function validDoc() {
  return {
    contract: { schemaName: "standard-director-contract", apiVersion: "v1", contractVersion: "1.0.0", mode: "observe-only" },
    metadata: { directorId: "d", projectId: "p", projectType: "test", environment: "sandbox", generation: 1 },
    spec: { lifecycleState: "bootstrap", autonomyLevel: "bounded-autonomous", capacity: { concurrencyLimit: 0 } },
    status: { phase: "bootstrap", health: "Healthy", observedGeneration: 1, lastObservedAt: new Date().toISOString() },
    conditions: [{ type: "Ready", status: "False", reason: "Bootstrap", message: "Not executable", severity: "info", lastTransitionTime: new Date().toISOString(), observedGeneration: 1 }],
    capabilities: { supportedTaskClasses: [], acceptedCommands: [] },
    security: { projectBoundary: "p", allowedScopes: ["observe"], crossProjectAccess: false },
    observability: { traceable: true, evidenceBacked: true },
    compatibility: { minMasterContractVersion: "1.0.0", maxMasterContractVersion: "1.x" }
  };
}

test("accepts a valid observe-only Director contract", () => {
  const result = validateObserveContract(validDoc());
  assert.equal(result.compliant, true);
  assert.deepEqual(result.errors, []);
});

test("rejects mutating commands in observe-only mode", () => {
  const doc = validDoc();
  doc.capabilities.acceptedCommands = ["set_capacity"];
  const result = validateObserveContract(doc);
  assert.equal(result.compliant, false);
  assert.ok(result.errors.includes("MUTATION_COMMANDS_NOT_ALLOWED_IN_OBSERVE_ONLY"));
});

test("rejects cross-project access", () => {
  const doc = validDoc();
  doc.security.crossProjectAccess = true;
  const result = validateObserveContract(doc);
  assert.equal(result.compliant, false);
  assert.ok(result.errors.includes("INVALID:security.crossProjectAccess"));
});

test("rejects stale contract structure", () => {
  const doc = validDoc();
  delete doc.status.observedGeneration;
  const result = validateObserveContract(doc);
  assert.equal(result.compliant, false);
  assert.ok(result.errors.some((e) => e.includes("status.observedGeneration")));
});
