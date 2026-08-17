export type VaultEndpointPolicy = {
  name: string;
  host: string;
  pathPrefixes?: readonly string[];
};

export type VaultAccessDecision =
  | { ok: true; endpoint: string }
  | {
      ok: false;
      code: 'SECRET_VAULT_ACCESS_INTERCEPTED' | 'INVALID_ACTION_ENDPOINT';
      endpoint: string;
      vault?: string;
      reason: string;
    };

export type VaultAccessAttempt = {
  action: string;
  endpoint: string;
};

function normalizeEndpoint(raw: string): URL | null {
  try {
    const url = new URL(raw);
    if (url.protocol !== 'https:' && url.protocol !== 'http:') return null;
    return url;
  } catch {
    return null;
  }
}

function normalizeHost(host: string): string {
  return host.trim().toLowerCase().replace(/\.$/, '');
}

function matchesVault(url: URL, policy: VaultEndpointPolicy): boolean {
  const host = normalizeHost(url.hostname);
  const expected = normalizeHost(policy.host);
  if (host !== expected && !host.endsWith(`.${expected}`)) return false;

  const prefixes = policy.pathPrefixes ?? [];
  if (prefixes.length === 0) return true;
  return prefixes.some((prefix) => url.pathname.startsWith(prefix));
}

export function inspectToolActionVaultAccess(
  attempt: VaultAccessAttempt,
  policies: readonly VaultEndpointPolicy[],
): VaultAccessDecision {
  const rawEndpoint = String(attempt.endpoint ?? '').trim();
  const url = normalizeEndpoint(rawEndpoint);
  if (!url) {
    return {
      ok: false,
      code: 'INVALID_ACTION_ENDPOINT',
      endpoint: rawEndpoint,
      reason: 'action_endpoint_must_be_absolute_http_url',
    };
  }

  for (const policy of policies) {
    if (matchesVault(url, policy)) {
      return {
        ok: false,
        code: 'SECRET_VAULT_ACCESS_INTERCEPTED',
        endpoint: url.origin + url.pathname,
        vault: policy.name,
        reason: 'direct_secret_vault_access_requires_controlled_broker',
      };
    }
  }

  return { ok: true, endpoint: url.origin + url.pathname };
}

export function assertNoDirectVaultAccess(
  attempt: VaultAccessAttempt,
  policies: readonly VaultEndpointPolicy[],
  onIntercept?: (decision: Exclude<VaultAccessDecision, { ok: true }>) => void,
): void {
  const decision = inspectToolActionVaultAccess(attempt, policies);
  if (decision.ok) return;
  onIntercept?.(decision);
  throw new Error(`${decision.code}:${decision.reason}`);
}

export function createVaultGuardedExecutor<T>(
  policies: readonly VaultEndpointPolicy[],
  execute: (attempt: VaultAccessAttempt) => Promise<T> | T,
  onIntercept?: (decision: Exclude<VaultAccessDecision, { ok: true }>) => void,
) {
  return async (attempt: VaultAccessAttempt): Promise<T> => {
    assertNoDirectVaultAccess(attempt, policies, onIntercept);
    return await execute(attempt);
  };
}
