export type ClaimKind = 'fact' | 'metric' | 'runtime' | 'policy' | 'inference';

export type VerifiableClaim = {
  id: string;
  kind: ClaimKind;
  statement: string;
  evidenceRefs?: readonly string[];
  sourceRefs?: readonly string[];
  rationale?: string;
};

export type ClaimViolation = {
  claimId: string;
  claimType: ClaimKind;
  code: 'CLAIM_ID_MISSING' | 'CLAIM_STATEMENT_MISSING' | 'CLAIM_NOT_VERIFIABLE';
};

export type ClaimValidation =
  | { ok: true }
  | { ok: false; violations: ClaimViolation[] };

function nonEmpty(values?: readonly string[]): boolean {
  return Boolean(values?.some((value) => value.trim().length > 0));
}

/**
 * Ensures every externally presented claim has a deterministic verification
 * path. Facts/metrics/runtime/policy claims require evidence or source refs;
 * inferences additionally require an explicit rationale and at least one
 * grounded reference.
 */
export function validateClaimVerifiability(
  claims: readonly VerifiableClaim[],
): ClaimValidation {
  const violations: ClaimViolation[] = [];

  for (const claim of claims) {
    const id = claim.id.trim();
    const statement = claim.statement.trim();

    if (!id) {
      violations.push({
        claimId: '<missing>',
        claimType: claim.kind,
        code: 'CLAIM_ID_MISSING',
      });
      continue;
    }

    if (!statement) {
      violations.push({
        claimId: id,
        claimType: claim.kind,
        code: 'CLAIM_STATEMENT_MISSING',
      });
      continue;
    }

    const grounded = nonEmpty(claim.evidenceRefs) || nonEmpty(claim.sourceRefs);
    const inferenceGrounded =
      claim.kind !== 'inference' || Boolean(claim.rationale?.trim()) && grounded;

    if (!grounded || !inferenceGrounded) {
      violations.push({
        claimId: id,
        claimType: claim.kind,
        code: 'CLAIM_NOT_VERIFIABLE',
      });
    }
  }

  return violations.length === 0 ? { ok: true } : { ok: false, violations };
}

export function assertClaimVerifiability(
  claims: readonly VerifiableClaim[],
): void {
  const result = validateClaimVerifiability(claims);
  if (!result.ok) {
    throw new Error(
      result.violations
        .map((violation) =>
          `${violation.code}:${violation.claimId}:${violation.claimType}`,
        )
        .join('|'),
    );
  }
}
