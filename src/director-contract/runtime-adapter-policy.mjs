const REQUIRED_RUNTIME_CAPABILITIES = [
  "durableExecution",
  "checkpointing",
  "observability"
];

export function validateRuntimeCandidate(candidate = {}) {
  const errors = [];
  if (!candidate.id) errors.push("MISSING:id");
  if (!candidate.mode) errors.push("MISSING:mode");
  if (candidate.mode !== "adapter-only") errors.push("RUNTIME_MUST_BE_ADAPTER_ONLY");

  for (const capability of REQUIRED_RUNTIME_CAPABILITIES) {
    if (candidate.capabilities?.[capability] !== true) {
      errors.push(`MISSING_CAPABILITY:${capability}`);
    }
  }

  const boundary = candidate.boundary || {};
  if (boundary.authoritativeDirector !== "project-director") {
    errors.push("DIRECTOR_AUTHORITY_MUST_REMAIN_LOCAL");
  }
  if (boundary.protectedStateWriter !== "project-director") {
    errors.push("PROTECTED_STATE_WRITER_MUST_REMAIN_LOCAL");
  }
  if (boundary.executionSafetyBypass !== false) {
    errors.push("EXECUTION_SAFETY_BYPASS_FORBIDDEN");
  }
  if (boundary.recoveryPolicyBypass !== false) {
    errors.push("RECOVERY_POLICY_BYPASS_FORBIDDEN");
  }
  if (boundary.fencingBypass !== false) {
    errors.push("FENCING_BYPASS_FORBIDDEN");
  }
  if (boundary.evidenceBypass !== false) {
    errors.push("EVIDENCE_BYPASS_FORBIDDEN");
  }
  if (boundary.crossProjectAccess !== false) {
    errors.push("CROSS_PROJECT_ACCESS_FORBIDDEN");
  }
  if (boundary.selfPromotion !== false) {
    errors.push("SELF_PROMOTION_FORBIDDEN");
  }

  return { valid: errors.length === 0, errors };
}

export function runtimeEligibleForSandbox(candidate = {}) {
  const validation = validateRuntimeCandidate(candidate);
  return validation.valid && candidate.status !== "discarded";
}

export const requiredRuntimeCapabilities = Object.freeze([...REQUIRED_RUNTIME_CAPABILITIES]);
