import { validateObserveContract } from "./conformance.mjs";

const SHARED_CORE_INVARIANTS = [
  ["contract.schemaName", "standard-director-contract"],
  ["contract.apiVersion", "v1"],
  ["contract.mode", "observe-only"],
  ["spec.autonomyLevel", "bounded-autonomous"],
  ["observability.traceable", true],
  ["observability.evidenceBacked", true],
  ["recovery.failurePolicyProfile", "director-recovery-v1"],
  ["recovery.leaseFencingRequired", true],
  ["recovery.evidenceRequiredForCompletion", true],
  ["recovery.checkpointStrategy", "last-safe-state"],
  ["security.crossProjectAccess", false],
];

function get(obj, path) {
  return path.split(".").reduce((cur, key) => cur?.[key], obj);
}

export function validatePortableDirectorPair(contentflow, opc) {
  const errors = [];
  const cf = validateObserveContract(contentflow);
  const op = validateObserveContract(opc);

  if (!cf.compliant) errors.push(...cf.errors.map((e) => `CONTENTFLOW:${e}`));
  if (!op.compliant) errors.push(...op.errors.map((e) => `OPC:${e}`));

  if (contentflow?.metadata?.projectId === opc?.metadata?.projectId) {
    errors.push("PROJECT_BOUNDARIES_MUST_BE_DISTINCT");
  }
  if (contentflow?.metadata?.directorId === opc?.metadata?.directorId) {
    errors.push("DIRECTOR_IDENTITIES_MUST_BE_DISTINCT");
  }

  for (const [path, expected] of SHARED_CORE_INVARIANTS) {
    if (get(contentflow, path) !== expected) errors.push(`CONTENTFLOW_CORE_DRIFT:${path}`);
    if (get(opc, path) !== expected) errors.push(`OPC_CORE_DRIFT:${path}`);
  }

  if (contentflow?.security?.projectBoundary !== contentflow?.metadata?.projectId) {
    errors.push("CONTENTFLOW_BOUNDARY_MISMATCH");
  }
  if (opc?.security?.projectBoundary !== opc?.metadata?.projectId) {
    errors.push("OPC_BOUNDARY_MISMATCH");
  }

  if ((contentflow?.capabilities?.acceptedCommands ?? []).length !== 0) {
    errors.push("CONTENTFLOW_OBSERVE_ONLY_COMMANDS_FORBIDDEN");
  }
  if ((opc?.capabilities?.acceptedCommands ?? []).length !== 0) {
    errors.push("OPC_OBSERVE_ONLY_COMMANDS_FORBIDDEN");
  }

  // OPC remains a portability probe, never an external executor in this gate.
  if (opc?.status?.executable !== false) errors.push("OPC_MUST_REMAIN_NON_EXECUTABLE");
  if (opc?.spec?.capacity?.concurrencyLimit !== 0) errors.push("OPC_CONCURRENCY_MUST_REMAIN_ZERO");

  return {
    portable: errors.length === 0,
    profile: "director-core-portability-v1",
    projects: [contentflow?.metadata?.projectId, opc?.metadata?.projectId],
    sharedInvariantCount: SHARED_CORE_INVARIANTS.length,
    errors,
  };
}
