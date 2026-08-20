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

export function validateSharedDirectorCore(manifest) {
  const errors = [];
  const conformance = validateObserveContract(manifest);

  if (!conformance.compliant) errors.push(...conformance.errors);

  for (const [path, expected] of SHARED_CORE_INVARIANTS) {
    if (get(manifest, path) !== expected) errors.push(`CORE_DRIFT:${path}`);
  }

  return {
    compliant: errors.length === 0,
    profile: "director-shared-core-v1",
    project: manifest?.metadata?.projectId,
    sharedInvariantCount: SHARED_CORE_INVARIANTS.length,
    errors,
  };
}

export function validateDirectorPair(left, right) {
  const errors = [];
  const leftCore = validateSharedDirectorCore(left);
  const rightCore = validateSharedDirectorCore(right);

  if (!leftCore.compliant) errors.push(...leftCore.errors.map((e) => `LEFT:${e}`));
  if (!rightCore.compliant) errors.push(...rightCore.errors.map((e) => `RIGHT:${e}`));

  if (left?.metadata?.projectId === right?.metadata?.projectId) {
    errors.push("PROJECT_BOUNDARIES_MUST_BE_DISTINCT");
  }
  if (left?.metadata?.directorId === right?.metadata?.directorId) {
    errors.push("DIRECTOR_IDENTITIES_MUST_BE_DISTINCT");
  }

  return {
    portable: errors.length === 0,
    profile: "director-core-portability-v1",
    projects: [left?.metadata?.projectId, right?.metadata?.projectId],
    sharedInvariantCount: SHARED_CORE_INVARIANTS.length,
    errors,
  };
}

export function validatePortableDirectorPair(contentflow, opc) {
  const pair = validateDirectorPair(contentflow, opc);
  const errors = [...pair.errors];

  // OPC remains a portability probe, never an external executor in this gate.
  if (opc?.status?.executable !== false) errors.push("OPC_MUST_REMAIN_NON_EXECUTABLE");
  if (opc?.spec?.capacity?.concurrencyLimit !== 0) errors.push("OPC_CONCURRENCY_MUST_REMAIN_ZERO");

  return {
    ...pair,
    portable: errors.length === 0,
    errors,
  };
}
