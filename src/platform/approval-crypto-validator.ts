export type ApprovalCryptoAlgorithm = 'ed25519+sha256';

export type ApprovalCryptoRecord = {
  approvalId: string;
  changeId: string;
  payloadHash: string;
  signature: string;
  signerKeyId: string;
  algorithm: ApprovalCryptoAlgorithm;
};

export type ApprovalChangeContext = {
  changeId: string;
  expectedPayloadHash: string;
};

export type ApprovalCryptoValidationReason =
  | 'valid'
  | 'not_implemented'
  | 'change_id_mismatch'
  | 'payload_hash_mismatch'
  | 'invalid_signature'
  | 'unsupported_algorithm'
  | 'verification_material_unavailable';

export type ApprovalCryptoValidationResult = {
  valid: boolean;
  reason: ApprovalCryptoValidationReason;
};

/**
 * Canonical approval cryptographic validation contract from
 * docs/architecture/adr-approval-crypto-validation.md.
 *
 * Implementations validate an approval record against the exact change context
 * and MUST fail closed when cryptographic verification is unavailable or has
 * not yet been implemented.
 */
export interface ApprovalCryptoValidator {
  validate(
    record: ApprovalCryptoRecord,
    context: ApprovalChangeContext,
  ): Promise<ApprovalCryptoValidationResult>;
}

/**
 * Minimal fail-closed stub implementing the ADR contract. Later tasks replace
 * the placeholder with signature and hash verification; until then this class
 * can never approve a change.
 */
export class FailClosedApprovalCryptoValidator implements ApprovalCryptoValidator {
  async validate(
    _record: ApprovalCryptoRecord,
    _context: ApprovalChangeContext,
  ): Promise<ApprovalCryptoValidationResult> {
    return { valid: false, reason: 'not_implemented' };
  }
}
