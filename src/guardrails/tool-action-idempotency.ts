export type ToolActionIdempotency = {
  action: string;
  idempotencyKey?: string;
  idempotent?: boolean;
  explicitlyPermittedNonIdempotent?: boolean;
};

export type IdempotencyDecision =
  | {
      ok: true;
      action: string;
      idempotent: boolean;
      idempotencyKey?: string;
      explicitlyPermittedNonIdempotent: boolean;
    }
  | {
      ok: false;
      code: 'IDEMPOTENCY_INVALID_ACTION' | 'IDEMPOTENCY_METADATA_REQUIRED' | 'NON_IDEMPOTENT_ACTION_DENIED';
      reason: string;
      action: string;
    };

function nonEmpty(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}

export function validateToolActionIdempotency(
  metadata: ToolActionIdempotency,
): IdempotencyDecision {
  const action = typeof metadata?.action === 'string' ? metadata.action.trim() : '';
  if (!action) {
    return {
      ok: false,
      code: 'IDEMPOTENCY_INVALID_ACTION',
      reason: 'missing_or_invalid_action',
      action,
    };
  }

  if (metadata.idempotent === true) {
    if (!nonEmpty(metadata.idempotencyKey)) {
      return {
        ok: false,
        code: 'IDEMPOTENCY_METADATA_REQUIRED',
        reason: 'idempotent_action_requires_idempotency_key',
        action,
      };
    }

    return {
      ok: true,
      action,
      idempotent: true,
      idempotencyKey: metadata.idempotencyKey.trim(),
      explicitlyPermittedNonIdempotent: false,
    };
  }

  if (metadata.idempotent === false && metadata.explicitlyPermittedNonIdempotent === true) {
    return {
      ok: true,
      action,
      idempotent: false,
      explicitlyPermittedNonIdempotent: true,
    };
  }

  if (metadata.idempotent === false) {
    return {
      ok: false,
      code: 'NON_IDEMPOTENT_ACTION_DENIED',
      reason: 'non_idempotent_action_not_explicitly_permitted',
      action,
    };
  }

  return {
    ok: false,
    code: 'IDEMPOTENCY_METADATA_REQUIRED',
    reason: 'action_must_declare_idempotency',
    action,
  };
}

export function assertToolActionIdempotency(
  metadata: ToolActionIdempotency,
  logDenial: (decision: Exclude<IdempotencyDecision, { ok: true }>) => void,
): IdempotencyDecision & { ok: true } {
  const decision = validateToolActionIdempotency(metadata);
  if (decision.ok) return decision;

  logDenial(decision);
  throw new Error(`${decision.code}:${decision.reason}`);
}
