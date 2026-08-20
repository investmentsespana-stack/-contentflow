import { recoveryDecision } from "./recovery-policy.mjs";
import { canAcceptWorkerResult, validateExecutionEnvelope } from "./execution-safety.mjs";

export const CERTIFICATION_PROFILE = "director-runtime-recovery-certification-v1";

function event(type, details = {}) {
  return { type, at: new Date(0).toISOString(), ...details };
}

export function runRecoveryScenario(scenario) {
  const events = [event("scenario_started", { scenario: scenario.name })];
  const decision = recoveryDecision(scenario.failureSignal || {});
  events.push(event("failure_classified", { failureClass: decision.failureClass, action: decision.action }));

  if (scenario.executionEnvelope) {
    const validation = validateExecutionEnvelope(scenario.executionEnvelope);
    events.push(event("execution_envelope_validated", { valid: validation.valid, errors: validation.errors }));
    if (!validation.valid) {
      return { passed: false, scenario: scenario.name, reason: "invalid_execution_envelope", decision, events };
    }
  }

  if (scenario.workerResult) {
    const accepted = canAcceptWorkerResult(scenario.workerResult);
    events.push(event("worker_result_checked", { accepted }));
    if (scenario.expectWorkerResultAccepted !== accepted) {
      return { passed: false, scenario: scenario.name, reason: "unexpected_fencing_result", decision, events };
    }
  }

  const expectedAction = scenario.expectedAction;
  if (expectedAction && decision.action !== expectedAction) {
    return { passed: false, scenario: scenario.name, reason: "unexpected_recovery_action", decision, events };
  }

  if (scenario.expectedRetryable !== undefined && decision.retryable !== scenario.expectedRetryable) {
    return { passed: false, scenario: scenario.name, reason: "unexpected_retry_policy", decision, events };
  }

  if (scenario.expectedHuman !== undefined && decision.requiresHuman !== scenario.expectedHuman) {
    return { passed: false, scenario: scenario.name, reason: "unexpected_human_escalation_policy", decision, events };
  }

  events.push(event("scenario_certified", { outcome: "pass" }));
  return { passed: true, scenario: scenario.name, decision, events };
}

export function defaultRecoveryCertificationScenarios(projectId = "contentflow") {
  const mutationEnvelope = {
    projectId,
    projectBoundary: projectId,
    intentId: "cert-intent",
    operationClass: "write",
    riskLevel: "medium",
    idempotencyKey: "cert-idempotency",
    expectedGeneration: 3,
    lease: { leaseId: "cert-lease", fencingToken: 12 },
  };

  return [
    {
      name: "worker-timeout-reclaims-and-reassigns",
      failureSignal: { code: "WORKER_TIMEOUT" },
      expectedAction: "reclaim_lease_and_reassign",
      expectedRetryable: true,
      executionEnvelope: mutationEnvelope,
    },
    {
      name: "rate-limit-backs-off",
      failureSignal: { status: 429 },
      expectedAction: "retry_after_backoff",
      expectedRetryable: true,
    },
    {
      name: "dependency-unavailable-opens-circuit",
      failureSignal: { status: 503 },
      expectedAction: "circuit_break_and_retry",
      expectedRetryable: true,
    },
    {
      name: "state-drift-reconciles",
      failureSignal: { kind: "state_drift" },
      expectedAction: "reconcile_desired_state",
      expectedRetryable: true,
    },
    {
      name: "missing-evidence-blocks-completion",
      failureSignal: { kind: "evidence_missing" },
      expectedAction: "block_completion",
      expectedRetryable: false,
    },
    {
      name: "lost-lease-fences-stale-worker",
      failureSignal: { kind: "lease_lost" },
      expectedAction: "fence_stale_worker",
      expectedRetryable: false,
      workerResult: { expectedFencingToken: 12, resultFencingToken: 11 },
      expectWorkerResultAccepted: false,
    },
    {
      name: "unknown-failure-fails-closed",
      failureSignal: { code: "UNRECOGNIZED_FAILURE" },
      expectedAction: "fail_closed_and_diagnose",
      expectedRetryable: false,
      expectedHuman: true,
    },
  ];
}

export function certifyRuntimeRecovery({ projectId = "contentflow", scenarios = defaultRecoveryCertificationScenarios(projectId) } = {}) {
  const results = scenarios.map(runRecoveryScenario);
  const passed = results.every((result) => result.passed);
  return {
    profile: CERTIFICATION_PROFILE,
    projectId,
    passed,
    promotionEligible: passed,
    passedScenarios: results.filter((result) => result.passed).length,
    totalScenarios: results.length,
    results,
  };
}
