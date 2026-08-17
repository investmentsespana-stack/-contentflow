import { expect, test } from '@playwright/test';
import {
  assertNoDirectVaultAccess,
  createVaultGuardedExecutor,
  inspectToolActionVaultAccess,
} from '../src/guardrails/tool-action-vault-access';

const policies = [
  { name: 'hashicorp-vault', host: 'vault.internal.example', pathPrefixes: ['/v1/secret', '/v1/kv'] },
  { name: 'aws-secrets-manager', host: 'secretsmanager.us-east-1.amazonaws.com' },
] as const;

test('flags configured HashiCorp Vault endpoint before execution', () => {
  expect(
    inspectToolActionVaultAccess(
      { action: 'http.request', endpoint: 'https://vault.internal.example/v1/secret/data/app' },
      policies,
    ),
  ).toEqual({
    ok: false,
    code: 'SECRET_VAULT_ACCESS_INTERCEPTED',
    endpoint: 'https://vault.internal.example/v1/secret/data/app',
    vault: 'hashicorp-vault',
    reason: 'direct_secret_vault_access_requires_controlled_broker',
  });
});

test('flags AWS Secrets Manager host and subdomains', () => {
  const decision = inspectToolActionVaultAccess(
    {
      action: 'http.request',
      endpoint: 'https://vpce-123.secretsmanager.us-east-1.amazonaws.com/',
    },
    policies,
  );
  expect(decision).toMatchObject({ ok: false, code: 'SECRET_VAULT_ACCESS_INTERCEPTED', vault: 'aws-secrets-manager' });
});

test('does not flag unrelated endpoints', () => {
  expect(
    inspectToolActionVaultAccess(
      { action: 'http.request', endpoint: 'https://api.example.com/v1/content' },
      policies,
    ),
  ).toEqual({ ok: true, endpoint: 'https://api.example.com/v1/content' });
});

test('rejects malformed endpoints fail-closed', () => {
  expect(() =>
    assertNoDirectVaultAccess({ action: 'http.request', endpoint: 'vault.internal.example/v1/secret' }, policies),
  ).toThrow('INVALID_ACTION_ENDPOINT:action_endpoint_must_be_absolute_http_url');
});

test('guarded executor blocks vault access before the underlying action runs', async () => {
  let executed = false;
  const interceptions: unknown[] = [];
  const executor = createVaultGuardedExecutor(
    policies,
    async () => {
      executed = true;
      return 'executed';
    },
    (entry) => interceptions.push(entry),
  );

  await expect(
    executor({ action: 'http.request', endpoint: 'https://vault.internal.example/v1/kv/team' }),
  ).rejects.toThrow('SECRET_VAULT_ACCESS_INTERCEPTED:direct_secret_vault_access_requires_controlled_broker');

  expect(executed).toBe(false);
  expect(interceptions).toHaveLength(1);
});

test('guarded executor allows unrelated network actions', async () => {
  const executor = createVaultGuardedExecutor(policies, async () => 'executed');
  await expect(
    executor({ action: 'http.request', endpoint: 'https://api.example.com/health' }),
  ).resolves.toBe('executed');
});
