export function evaluateAutonomyAdmission(input={}) {
  const nowMs = Number(input.nowMs ?? Date.now());
  const recovery = input.recovery || {};
  const recoveryAgeMs = recovery.verifiedAt ? Math.max(0, nowMs - new Date(recovery.verifiedAt).getTime()) : Number.POSITIVE_INFINITY;
  const recoveryFresh = recovery.verified === true && String(recovery.status || '').toUpperCase() === 'PASS' && recoveryAgeMs <= 7 * 24 * 60 * 60 * 1000;
  const ownershipConflicts = Number(input.ownershipConflicts || 0);
  const openIncidents = Number(input.openIncidents || 0);
  const openCircuits = Number(input.openCircuits || 0);
  const retryStates = Math.max(0, Number(input.retryStates || 0));
  const retryOpenRate = retryStates ? openCircuits / retryStates : 0;
  const waitingForEvidence = Number(input.waitingForEvidence || 0);
  const requested = Math.max(0, Number(input.requestedParallelism || 0));
  const stableCap = Math.max(0, Number(input.stableParallelism || 2));

  const blockers = [];
  if (!recoveryFresh) blockers.push('recovery_not_certified');
  if (ownershipConflicts > 0) blockers.push('ownership_conflict');
  if (openIncidents > 0) blockers.push('open_repair_incident');
  if (retryOpenRate > 0.25 || openCircuits > 2) blockers.push('retry_budget_unhealthy');
  if (waitingForEvidence > 0) blockers.push('evidence_producer_gap');

  const admitted = blockers.length === 0;
  const effectiveParallelism = admitted ? Math.min(requested, stableCap) : 0;
  return {
    admitted,
    mode: admitted ? 'productive' : 'support_only',
    effectiveParallelism,
    requestedParallelism: requested,
    stableParallelism: stableCap,
    blockers,
    signals: {
      recoveryFresh,
      recoveryAgeMs: Number.isFinite(recoveryAgeMs) ? recoveryAgeMs : null,
      ownershipConflicts,
      openIncidents,
      openCircuits,
      retryStates,
      retryOpenRate,
      waitingForEvidence
    }
  };
}
