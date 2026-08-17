export type AtomicAuthorizationClaims = {
  principalId: string;
  allowedActions: readonly string[];
  expiresAt?: string;
};

export type AuthorizationDecision =
  | { ok: true; principalId: string; action: string }
  | {
      ok: false;
      code: 'AUTHZ_INVALID_CLAIMS' | 'AUTHZ_EXPIRED' | 'AUTHZ_ACTION_DENIED';
      reason: string;
      principalId?: string;
      action: string;
    };

function isNonEmptyString(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}

function normalizeActions(actions: readonly string[]): Set<string> {
  return new Set(actions.filter(isNonEmptyString).map((value) => value.trim()));
}

export function authorizeToolAction(
  action: string,
  claims: AtomicAuthorizationClaims | null | undefined,
  now: Date = new Date(),
): AuthorizationDecision {
  const normalizedAction = action.trim();

  if (
    !normalizedAction ||
    !claims ||
    !isNonEmptyString(claims.principalId) ||
    !Array.isArray(claims.allowedActions)
  ) {
    return {
      ok: false,
      code: 'AUTHZ_INVALID_CLAIMS',
      reason: 'missing_or_invalid_atomic_authorization_claims',
      action: normalizedAction,
    };
  }

  if (claims.expiresAt) {
    const expiresAt = Date.parse(claims.expiresAt);
    if (!Number.isFinite(expiresAt) || expiresAt <= now.getTime()) {
      return {
        ok: false,
        code: 'AUTHZ_EXPIRED',
        reason: 'atomic_authorization_claims_expired_or_invalid',
        principalId: claims.principalId,
        action: normalizedAction,
      };
    }
  }

  const allowed = normalizeActions(claims.allowedActions);
  if (!allowed.has(normalizedAction)) {
    return {
      ok: false,
      code: 'AUTHZ_ACTION_DENIED',
      reason: `action_not_authorized:${normalizedAction}`,
      principalId: claims.principalId,
      action: normalizedAction,
    };
  }

  return {
    ok: true,
    principalId: claims.principalId,
    action: normalizedAction,
  };
}

export function assertToolActionAuthorized(
  action: string,
  claims: AtomicAuthorizationClaims | null | undefined,
  logDenial: (entry: Exclude<AuthorizationDecision, { ok: true }>) => void,
  now: Date = new Date(),
): void {
  const decision = authorizeToolAction(action, claims, now);
  if (decision.ok) return;

  logDenial(decision);
  throw new Error(`${decision.code}:${decision.reason}`);
}
