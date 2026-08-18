export const SDC_V1 = "1.0.0";

const CONDITION_FIELDS = ["type", "status", "reason", "message", "severity", "lastTransitionTime", "observedGeneration"];

function get(obj, path) {
  let cur = obj;
  for (const part of path.split(".")) {
    if (cur == null || typeof cur !== "object" || !(part in cur)) return undefined;
    cur = cur[part];
  }
  return cur;
}

function has(obj, path) {
  const value = get(obj, path);
  return value !== undefined && value !== null;
}

export function validateObserveContract(doc) {
  const errors = [];
  const required = [
    "contract.schemaName", "contract.apiVersion", "contract.contractVersion", "contract.mode",
    "metadata.directorId", "metadata.projectId", "metadata.projectType", "metadata.environment", "metadata.generation",
    "spec.lifecycleState", "spec.autonomyLevel", "spec.capacity.concurrencyLimit",
    "status.phase", "status.health", "status.observedGeneration",
    "capabilities.supportedTaskClasses", "capabilities.acceptedCommands",
    "security.projectBoundary", "security.allowedScopes", "security.crossProjectAccess",
    "observability.traceable", "observability.evidenceBacked",
    "recovery.failurePolicyProfile", "recovery.leaseFencingRequired", "recovery.evidenceRequiredForCompletion",
    "compatibility.minMasterContractVersion", "compatibility.maxMasterContractVersion"
  ];

  for (const path of required) if (!has(doc, path)) errors.push(`MISSING:${path}`);

  if (doc?.contract?.schemaName !== "standard-director-contract") errors.push("INVALID:contract.schemaName");
  if (doc?.contract?.apiVersion !== "v1") errors.push("INVALID:contract.apiVersion");
  if (doc?.contract?.contractVersion !== SDC_V1) errors.push("INVALID:contract.contractVersion");
  if (doc?.contract?.mode !== "observe-only") errors.push("INVALID:contract.mode");
  if (doc?.security?.crossProjectAccess !== false) errors.push("INVALID:security.crossProjectAccess");
  if (doc?.security?.projectBoundary !== doc?.metadata?.projectId) errors.push("INVALID:security.projectBoundary");
  if (!Array.isArray(doc?.capabilities?.acceptedCommands) || doc.capabilities.acceptedCommands.length !== 0) errors.push("MUTATION_COMMANDS_NOT_ALLOWED_IN_OBSERVE_ONLY");
  if (!Array.isArray(doc?.security?.allowedScopes) || !doc.security.allowedScopes.includes("observe")) errors.push("OBSERVE_SCOPE_REQUIRED");
  if (!Number.isInteger(doc?.metadata?.generation) || doc.metadata.generation < 1) errors.push("INVALID:metadata.generation");
  if (!Number.isInteger(doc?.status?.observedGeneration) || doc.status.observedGeneration < 1) errors.push("INVALID:status.observedGeneration");
  if (doc?.status?.observedGeneration > doc?.metadata?.generation) errors.push("INVALID:observedGeneration_ahead_of_generation");
  if (!Number.isInteger(doc?.spec?.capacity?.concurrencyLimit) || doc.spec.capacity.concurrencyLimit < 0) errors.push("INVALID:spec.capacity.concurrencyLimit");
  if (doc?.recovery?.leaseFencingRequired !== true) errors.push("LEASE_FENCING_REQUIRED");
  if (doc?.recovery?.evidenceRequiredForCompletion !== true) errors.push("EVIDENCE_REQUIRED_FOR_COMPLETION");

  if (!Array.isArray(doc?.conditions)) errors.push("MISSING:conditions");
  else for (let i = 0; i < doc.conditions.length; i++) {
    const c = doc.conditions[i] || {};
    for (const field of CONDITION_FIELDS) if (!(field in c)) errors.push(`MISSING:conditions[${i}].${field}`);
    if (!["True", "False", "Unknown"].includes(c.status)) errors.push(`INVALID:conditions[${i}].status`);
    if (!["info", "warning", "critical"].includes(c.severity)) errors.push(`INVALID:conditions[${i}].severity`);
  }

  return { compliant: errors.length === 0, profile: "SDC-v1-observe", contractVersion: SDC_V1, errors };
}
