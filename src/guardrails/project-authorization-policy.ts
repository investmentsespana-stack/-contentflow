import type { AtomicAuthorizationClaims } from './tool-action-authz';

export type ProjectAuthorizationPolicy = {
  projectId: string;
  principalId: string;
  allowedActions: readonly string[];
  expiresAt?: string;
};

function isNonEmpty(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}

export function claimsFromProjectPolicy(
  expectedProjectId: string,
  policy: ProjectAuthorizationPolicy | null | undefined,
): AtomicAuthorizationClaims | undefined {
  if (
    !policy ||
    !isNonEmpty(expectedProjectId) ||
    !isNonEmpty(policy.projectId) ||
    policy.projectId.trim() !== expectedProjectId.trim() ||
    !isNonEmpty(policy.principalId) ||
    !Array.isArray(policy.allowedActions)
  ) {
    return undefined;
  }

  return {
    principalId: policy.principalId.trim(),
    allowedActions: [...policy.allowedActions],
    ...(policy.expiresAt ? { expiresAt: policy.expiresAt } : {}),
  };
}
