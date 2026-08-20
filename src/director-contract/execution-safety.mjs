export const MUTATING_OPERATION_CLASSES = new Set(["write", "external-effect", "destructive"]);
export const HIGH_RISK_OPERATION_CLASSES = new Set(["external-effect", "destructive"]);

function isNonEmptyString(value) {
  return typeof value === "string" && value.trim().length > 0;
}

export function validateExecutionEnvelope(envelope = {}) {
  const errors = [];
  const required = ["projectId", "intentId", "operationClass", "riskLevel", "projectBoundary"];
  for (const field of required) if (!isNonEmptyString(envelope[field])) errors.push(`MISSING:${field}`);

  const operationClass = envelope.operationClass;
  if (!["observe", "read", "write", "external-effect", "destructive"].includes(operationClass)) {
    errors.push("INVALID:operationClass");
  }
  if (!["low", "medium", "high", "critical"].includes(envelope.riskLevel)) {
    errors.push("INVALID:riskLevel");
  }
  if (envelope.projectId && envelope.projectBoundary && envelope.projectId !== envelope.projectBoundary) {
    errors.push("CROSS_PROJECT_BOUNDARY_DENIED");
  }

  if (MUTATING_OPERATION_CLASSES.has(operationClass)) {
    if (!isNonEmptyString(envelope.idempotencyKey)) errors.push("MISSING:idempotencyKey");
    if (!Number.isInteger(envelope.expectedGeneration) || envelope.expectedGeneration < 1) errors.push("MISSING_OR_INVALID:expectedGeneration");
    if (!isNonEmptyString(envelope.lease?.leaseId)) errors.push("MISSING:lease.leaseId");
    if (!Number.isInteger(envelope.lease?.fencingToken) || envelope.lease.fencingToken < 1) errors.push("MISSING_OR_INVALID:lease.fencingToken");
  }

  if (HIGH_RISK_OPERATION_CLASSES.has(operationClass) || ["high", "critical"].includes(envelope.riskLevel)) {
    if (!isNonEmptyString(envelope.authorization?.approvalId)) errors.push("MISSING:authorization.approvalId");
    if (!isNonEmptyString(envelope.authorization?.payloadHash)) errors.push("MISSING:authorization.payloadHash");
    if (!isNonEmptyString(envelope.authorization?.expiresAt)) errors.push("MISSING:authorization.expiresAt");
  }

  if (operationClass === "external-effect" || operationClass === "destructive") {
    if (!Array.isArray(envelope.evidenceRequired) || envelope.evidenceRequired.length === 0) {
      errors.push("EVIDENCE_REQUIRED_FOR_EXTERNAL_EFFECT");
    }
  }

  return {
    valid: errors.length === 0,
    profile: "director-execution-safety-v1",
    errors,
  };
}

export function canAcceptWorkerResult({ expectedFencingToken, resultFencingToken }) {
  return Number.isInteger(expectedFencingToken)
    && Number.isInteger(resultFencingToken)
    && expectedFencingToken === resultFencingToken;
}
