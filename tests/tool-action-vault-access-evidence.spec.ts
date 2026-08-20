import { mkdirSync, writeFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import {
  assertNoDirectVaultAccess,
  createVaultGuardedExecutor,
  inspectToolActionVaultAccess,
} from '../src/guardrails/tool-action-vault-access';

const evidencePath = 'test-results/tool-action-vault-access-evidence.json';
const policies = [
  { name: 'hashicorp-vault', host: 'vault.internal.example', pathPrefixes: ['/v1/secret', '/v1/kv'] },
  { name: 'aws-secrets-manager', host: 'secretsmanager.us-east-1.amazonaws.com' },
] as const;

test('certifies direct vault access is intercepted before execution and persists deterministic evidence', async () => {
  let underlyingActionExecuted = false;
  const interceptions: unknown[] = [];

  const executor = createVaultGuardedExecutor(
    policies,
    async () => {
      underlyingActionExecuted = true;
      return 'executed';
    },
    (entry) => interceptions.push(entry),
  );

  const hashicorp = inspectToolActionVaultAccess(
    { action: 'http.request', endpoint: 'https://vault.internal.example/v1/secret/data/app' },
    policies,
  );
  const aws = inspectToolActionVaultAccess(
    { action: 'http.request', endpoint: 'https://vpce-123.secretsmanager.us-east-1.amazonaws.com/' },
    policies,
  );
  const clean = inspectToolActionVaultAccess(
    { action: 'http.request', endpoint: 'https://api.example.com/health' },
    policies,
  );

  await expect(
    executor({ action: 'http.request', endpoint: 'https://vault.internal.example/v1/kv/team' }),
  ).rejects.toThrow('SECRET_VAULT_ACCESS_INTERCEPTED:direct_secret_vault_access_requires_controlled_broker');

  let malformedRejected = false;
  try {
    assertNoDirectVaultAccess(
      { action: 'http.request', endpoint: 'vault.internal.example/v1/secret' },
      policies,
    );
  } catch (error) {
    malformedRejected = String(error).includes('INVALID_ACTION_ENDPOINT:action_endpoint_must_be_absolute_http_url');
  }

  const cleanExecutor = createVaultGuardedExecutor(policies, async () => 'executed');
  const cleanExecutionResult = await cleanExecutor({
    action: 'http.request',
    endpoint: 'https://api.example.com/health',
  });

  expect(underlyingActionExecuted).toBe(false);
  expect(interceptions).toHaveLength(1);
  expect(hashicorp).toMatchObject({ ok: false, code: 'SECRET_VAULT_ACCESS_INTERCEPTED', vault: 'hashicorp-vault' });
  expect(aws).toMatchObject({ ok: false, code: 'SECRET_VAULT_ACCESS_INTERCEPTED', vault: 'aws-secrets-manager' });
  expect(clean).toEqual({ ok: true, endpoint: 'https://api.example.com/health' });
  expect(malformedRejected).toBe(true);
  expect(cleanExecutionResult).toBe('executed');

  const evidence = {
    schemaVersion: 1,
    guardrail: 'tool-action-vault-access',
    invariant: 'direct secret-vault access is intercepted before underlying execution',
    failClosedBeforeExecution: !underlyingActionExecuted,
    interceptionLogged: interceptions.length === 1,
    malformedEndpointRejected: malformedRejected,
    cleanTrafficAllowed: cleanExecutionResult === 'executed',
    cases: { hashicorp, awsSecretsManager: aws, cleanEndpoint: clean },
  };

  mkdirSync('test-results', { recursive: true });
  writeFileSync(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
});
