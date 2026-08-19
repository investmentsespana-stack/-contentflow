import test from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import { validateObserveContract } from "../src/director-contract/conformance.mjs";
import { classifyFailure, recoveryDecision } from "../src/director-contract/recovery-policy.mjs";
import { validateExecutionEnvelope, canAcceptWorkerResult } from "../src/director-contract/execution-safety.mjs";
import { validateRuntimeCandidate, runtimeEligibleForSandbox } from "../src/director-contract/runtime-adapter-policy.mjs";

async function readJson(path) {
  return JSON.parse(await readFile(new URL(path, import.meta.url), "utf8"));
}

test("ContentFlow and OPC manifests conform to SDC-v1 observe profile", async () => {
  const contentflow = await readJson("../projects/contentflow/director-manifest.v1.json");
  const opc = await readJson("../projects/opc/director-manifest.v1.json");
  assert.deepEqual(validateObserveContract(contentflow).errors, []);
  assert.deepEqual(validateObserveContract(opc).errors, []);
});

test("failure classification is deterministic and fail-closed", () => {
  assert.equal(classifyFailure({ status: 429 }), "rate_limited");
  assert.equal(classifyFailure({ status: 403 }), "authorization_denied");
  assert.equal(classifyFailure({ code: "WORKER_TIMEOUT" }), "worker_timeout");
  assert.equal(classifyFailure({ code: "something_new" }), "unknown");
  assert.equal(recoveryDecision({ code: "something_new" }).action, "fail_closed_and_diagnose");
});

test("mutating execution requires idempotency, generation and lease fencing", () => {
  const result = validateExecutionEnvelope({
    projectId: "contentflow",
    projectBoundary: "contentflow",
    intentId: "intent-1",
    operationClass: "write",
    riskLevel: "medium"
  });
  assert.equal(result.valid, false);
  assert.ok(result.errors.includes("MISSING:idempotencyKey"));
  assert.ok(result.errors.includes("MISSING_OR_INVALID:expectedGeneration"));
  assert.ok(result.errors.includes("MISSING:lease.leaseId"));
});

test("high-risk external effect requires bound approval and evidence", () => {
  const result = validateExecutionEnvelope({
    projectId: "opc",
    projectBoundary: "opc",
    intentId: "intent-2",
    operationClass: "external-effect",
    riskLevel: "high",
    idempotencyKey: "idem-2",
    expectedGeneration: 2,
    lease: { leaseId: "lease-2", fencingToken: 4 }
  });
  assert.equal(result.valid, false);
  assert.ok(result.errors.includes("MISSING:authorization.approvalId"));
  assert.ok(result.errors.includes("MISSING:authorization.payloadHash"));
  assert.ok(result.errors.includes("EVIDENCE_REQUIRED_FOR_EXTERNAL_EFFECT"));
});

test("stale worker result is rejected by fencing token", () => {
  assert.equal(canAcceptWorkerResult({ expectedFencingToken: 8, resultFencingToken: 7 }), false);
  assert.equal(canAcceptWorkerResult({ expectedFencingToken: 8, resultFencingToken: 8 }), true);
});

test("external runtimes remain adapters and cannot replace project Director authority", async () => {
  const matrix = await readJson("../projects/shared/runtime-adoption-matrix.v1.json");
  for (const candidate of matrix.candidates) {
    assert.deepEqual(validateRuntimeCandidate(candidate).errors, []);
    assert.equal(runtimeEligibleForSandbox(candidate), true);
  }
});

test("runtime adapter fails closed if it can bypass fencing or project authority", () => {
  const unsafe = {
    id: "unsafe-runtime",
    mode: "adapter-only",
    status: "candidate",
    capabilities: { durableExecution: true, checkpointing: true, observability: true },
    boundary: {
      authoritativeDirector: "external-runtime",
      protectedStateWriter: "external-runtime",
      executionSafetyBypass: false,
      recoveryPolicyBypass: false,
      fencingBypass: true,
      evidenceBypass: false,
      crossProjectAccess: false,
      selfPromotion: false
    }
  };
  const result = validateRuntimeCandidate(unsafe);
  assert.equal(result.valid, false);
  assert.ok(result.errors.includes("DIRECTOR_AUTHORITY_MUST_REMAIN_LOCAL"));
  assert.ok(result.errors.includes("PROTECTED_STATE_WRITER_MUST_REMAIN_LOCAL"));
  assert.ok(result.errors.includes("FENCING_BYPASS_FORBIDDEN"));
});
