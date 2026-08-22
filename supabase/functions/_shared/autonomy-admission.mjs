import { validateRecoveryReceipt } from './recovery-certification-receipt.mjs';
import { evaluateBudgetAdmission } from './budget-admission.mjs';

export function evaluateAutonomyAdmission(input={}) {
  const nowMs = Number(input.nowMs ?? Date.now());
  const telemetryHealthy = input.telemetryHealthy !== false;
  const ownershipConflicts = Number(input.ownershipConflicts || 0);
  const openIncidents = Number(input.openIncidents || 0);
  const openCircuits = Number(input.openCircuits || 0);
  const retryStates = Math.max(0, Number(input.retryStates || 0));
  const retryOpenRate = retryStates ? openCircuits / retryStates : 0;
  const waitingForEvidence = Number(input.waitingForEvidence || 0);
  const requested = Math.max(0, Number(input.requestedParallelism || 0));
  const stableCap = Math.max(0, Number(input.stableParallelism || 2));
  const minimumDwellMs = Math.max(0, Number(input.minimumDwellMs ?? 5 * 60 * 1000));

  const receiptValidation = validateRecoveryReceipt(input.recoveryReceipt || {}, { nowMs });
  const healthySinceMs = receiptValidation.receipt.healthySince ? Date.parse(receiptValidation.receipt.healthySince) : NaN;
  const healthyDwellMs = Number.isFinite(healthySinceMs) ? Math.max(0, nowMs - healthySinceMs) : 0;
  const dwellSatisfied = receiptValidation.valid && healthyDwellMs >= minimumDwellMs;
  const budgetAdmission = evaluateBudgetAdmission(input.budget || {});

  const blockers = [];
  if (!telemetryHealthy) blockers.push('admission_telemetry_unavailable');
  if (!receiptValidation.valid) blockers.push('recovery_receipt_invalid');
  if (receiptValidation.valid && !dwellSatisfied) blockers.push('stability_dwell_pending');
  if (!budgetAdmission.admitted) blockers.push(...budgetAdmission.blockers);
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
      telemetryHealthy,
      recoveryReceiptValid: receiptValidation.valid,
      recoveryReceiptErrors: receiptValidation.errors,
      recoveryReceiptAgeMs: receiptValidation.ageMs,
      healthyDwellMs,
      minimumDwellMs,
      dwellSatisfied,
      providerBudgetAdmitted:budgetAdmission.admitted,
      providerBudget:budgetAdmission,
      ownershipConflicts,
      openIncidents,
      openCircuits,
      retryStates,
      retryOpenRate,
      waitingForEvidence
    }
  };
}
