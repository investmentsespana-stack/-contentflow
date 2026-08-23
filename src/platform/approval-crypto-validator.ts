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

export interface ApprovalCryptoValidator {
  validate(
    record: ApprovalCryptoRecord,
    context: ApprovalChangeContext,
  ): Promise<ApprovalCryptoValidationResult>;
}

export interface ApprovalPublicKeyResolver {
  resolvePublicKey(signerKeyId: string): Promise<CryptoKey | null>;
}

export type ApprovalValidationEvent = {
  event: 'approval_validation_succeeded' | 'approval_validation_failed';
  approvalId: string;
  changeId: string;
  signerKeyId: string;
  reason: ApprovalCryptoValidationReason;
};

export interface ApprovalValidationEventSink {
  record(event: ApprovalValidationEvent): Promise<void> | void;
}

function decodeBase64Url(value: string): Uint8Array | null {
  try {
    const normalized = value.replace(/-/g, '+').replace(/_/g, '/');
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, '=');
    const raw = atob(padded);
    return Uint8Array.from(raw, (char) => char.charCodeAt(0));
  } catch {
    return null;
  }
}

export function canonicalApprovalMessage(record: ApprovalCryptoRecord): Uint8Array {
  return new TextEncoder().encode(
    JSON.stringify({
      approvalId: record.approvalId,
      changeId: record.changeId,
      payloadHash: record.payloadHash,
      signerKeyId: record.signerKeyId,
      algorithm: record.algorithm,
    }),
  );
}

/**
 * Production-capable Ed25519 verifier. Public-key lookup is injected so the
 * validator can bind to the platform PKI without embedding keys or granting the
 * validator direct storage access. Every unavailable/invalid condition fails
 * closed. Signatures cover all immutable approval identity fields plus the
 * SHA-256 payload hash.
 */
export class Ed25519ApprovalCryptoValidator implements ApprovalCryptoValidator {
  constructor(
    private readonly keys: ApprovalPublicKeyResolver,
    private readonly events?: ApprovalValidationEventSink,
  ) {}

  private async finish(
    record: ApprovalCryptoRecord,
    result: ApprovalCryptoValidationResult,
  ): Promise<ApprovalCryptoValidationResult> {
    await this.events?.record({
      event: result.valid ? 'approval_validation_succeeded' : 'approval_validation_failed',
      approvalId: record.approvalId,
      changeId: record.changeId,
      signerKeyId: record.signerKeyId,
      reason: result.reason,
    });
    return result;
  }

  async validate(
    record: ApprovalCryptoRecord,
    context: ApprovalChangeContext,
  ): Promise<ApprovalCryptoValidationResult> {
    if (record.algorithm !== 'ed25519+sha256') {
      return this.finish(record, { valid: false, reason: 'unsupported_algorithm' });
    }
    if (record.changeId !== context.changeId) {
      return this.finish(record, { valid: false, reason: 'change_id_mismatch' });
    }
    if (record.payloadHash !== context.expectedPayloadHash) {
      return this.finish(record, { valid: false, reason: 'payload_hash_mismatch' });
    }
    if (!record.signature.trim()) {
      return this.finish(record, { valid: false, reason: 'invalid_signature' });
    }

    const publicKey = await this.keys.resolvePublicKey(record.signerKeyId);
    if (!publicKey) {
      return this.finish(record, {
        valid: false,
        reason: 'verification_material_unavailable',
      });
    }

    const signature = decodeBase64Url(record.signature);
    if (!signature) {
      return this.finish(record, { valid: false, reason: 'invalid_signature' });
    }

    try {
      const valid = await crypto.subtle.verify(
        { name: 'Ed25519' },
        publicKey,
        signature,
        canonicalApprovalMessage(record),
      );
      return this.finish(
        record,
        valid ? { valid: true, reason: 'valid' } : { valid: false, reason: 'invalid_signature' },
      );
    } catch {
      return this.finish(record, {
        valid: false,
        reason: 'verification_material_unavailable',
      });
    }
  }
}

/**
 * Explicit emergency fallback for environments where PKI is not configured.
 * It remains fail closed and is not the production verifier.
 */
export class FailClosedApprovalCryptoValidator implements ApprovalCryptoValidator {
  async validate(
    _record: ApprovalCryptoRecord,
    _context: ApprovalChangeContext,
  ): Promise<ApprovalCryptoValidationResult> {
    return { valid: false, reason: 'not_implemented' };
  }
}

export class ApprovalIngestionGate {
  constructor(private readonly validator: ApprovalCryptoValidator) {}

  async ingest(
    record: ApprovalCryptoRecord,
    context: ApprovalChangeContext,
  ): Promise<{ accepted: boolean; reason: ApprovalCryptoValidationReason }> {
    const result = await this.validator.validate(record, context);
    return { accepted: result.valid, reason: result.reason };
  }
}
