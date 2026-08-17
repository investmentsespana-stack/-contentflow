export type AssumptionKind =
  | 'sanitized'
  | 'trusted_enum'
  | 'trusted_source'
  | 'validated_format';

export type AssumptionClaim = {
  field: string;
  kind: AssumptionKind;
};

export type ContractGuarantee = AssumptionClaim;

export type AssumptionValidation =
  | { ok: true }
  | { ok: false; violations: string[] };

function key(value: AssumptionClaim): string {
  return `${value.field}:${value.kind}`;
}

/**
 * Rejects payload processing when callers rely on trust properties that the
 * interface contract does not explicitly guarantee.
 *
 * The guardrail is deliberately fail-closed: a claimed assumption is valid
 * only when an identical field/kind guarantee exists in the contract.
 */
export function validateContractAssumptions(
  input: Record<string, unknown>,
  claims: readonly AssumptionClaim[],
  guarantees: readonly ContractGuarantee[],
): AssumptionValidation {
  const guaranteed = new Set(guarantees.map(key));
  const violations: string[] = [];

  for (const claim of claims) {
    if (!Object.prototype.hasOwnProperty.call(input, claim.field)) {
      violations.push(`ASSUMPTION_FIELD_MISSING:${key(claim)}`);
      continue;
    }

    if (!guaranteed.has(key(claim))) {
      violations.push(`UNVERIFIED_ASSUMPTION:${key(claim)}`);
    }
  }

  return violations.length === 0 ? { ok: true } : { ok: false, violations };
}

export function assertContractAssumptions(
  input: Record<string, unknown>,
  claims: readonly AssumptionClaim[],
  guarantees: readonly ContractGuarantee[],
): void {
  const result = validateContractAssumptions(input, claims, guarantees);
  if (!result.ok) {
    throw new Error(result.violations.join('|'));
  }
}
