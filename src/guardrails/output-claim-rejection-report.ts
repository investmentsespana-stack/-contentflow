import { validateClaimVerifiability, type VerifiableClaim } from './output-claim-verifiability';

export type ClaimRejection = {
  claimId: string;
  claimType: string;
  code: string;
  statement: string;
};

export type ClaimRejectionReport = {
  schemaVersion: '1.0';
  passed: boolean;
  rejectedClaims: ClaimRejection[];
};

/** Produces a deterministic, serializable report for every non-verifiable claim. */
export function generateClaimRejectionReport(
  claims: readonly VerifiableClaim[],
): ClaimRejectionReport {
  const validation = validateClaimVerifiability(claims);
  if (validation.ok) {
    return { schemaVersion: '1.0', passed: true, rejectedClaims: [] };
  }

  const byId = new Map(claims.map((claim) => [claim.id.trim() || '<missing>', claim]));
  return {
    schemaVersion: '1.0',
    passed: false,
    rejectedClaims: validation.violations.map((violation) => ({
      claimId: violation.claimId,
      claimType: violation.claimType,
      code: violation.code,
      statement: byId.get(violation.claimId)?.statement ?? '',
    })),
  };
}
