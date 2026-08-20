import test from "node:test";
import assert from "node:assert/strict";
import { certifyRuntimeRecovery, defaultRecoveryCertificationScenarios } from "../src/director-contract/runtime-recovery-certification.mjs";

test("ContentFlow certifies seven recovery scenarios", () => {
  const result = certifyRuntimeRecovery({ projectId: "contentflow" });
  assert.equal(result.passed, true);
  assert.equal(result.promotionEligible, true);
  assert.equal(result.passedScenarios, 7);
  assert.equal(result.totalScenarios, 7);
});

test("OPC uses the same recovery certification contract", () => {
  const result = certifyRuntimeRecovery({ projectId: "opc" });
  assert.equal(result.passed, true);
  assert.equal(result.promotionEligible, true);
  assert.equal(result.passedScenarios, 7);
});

test("promotion is denied when a required scenario does not recover as expected", () => {
  const scenarios = defaultRecoveryCertificationScenarios("contentflow");
  scenarios[0] = { ...scenarios[0], expectedAction: "unexpected_action" };
  const result = certifyRuntimeRecovery({ projectId: "contentflow", scenarios });
  assert.equal(result.passed, false);
  assert.equal(result.promotionEligible, false);
});

test("promotion is denied when a mutating recovery lacks a fencing token", () => {
  const scenarios = defaultRecoveryCertificationScenarios("contentflow");
  scenarios[0] = {
    ...scenarios[0],
    executionEnvelope: {
      ...scenarios[0].executionEnvelope,
      lease: { leaseId: "cert-lease" }
    }
  };
  const result = certifyRuntimeRecovery({ projectId: "contentflow", scenarios });
  assert.equal(result.passed, false);
  assert.equal(result.promotionEligible, false);
});
