import { mkdirSync, writeFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import { assertToolActionAuthorized, authorizeToolAction } from '../src/guardrails/tool-action-authz';

const now = new Date('2026-08-17T10:00:00.000Z');
const evidencePath = 'test-results/tool-action-allowlist-evidence.json';

test('certifies tool action allowlist fail-closed behavior and persists deterministic evidence', () => {
  let underlyingActionExecuted = false;
  const denials: unknown[] = [];

  expect(() => {
    assertToolActionAuthorized(
      'github.delete_file',
      {
        principalId: 'evidence-agent',
        allowedActions: ['github.fetch_file'],
        expiresAt: '2026-08-17T11:00:00.000Z',
      },
      (entry) => denials.push(entry),
      now,
    );
    underlyingActionExecuted = true;
  }).toThrow('AUTHZ_ACTION_DENIED:action_not_authorized:github.delete_file');

  const denied = authorizeToolAction(
    'github.delete_file',
    {
      principalId: 'evidence-agent',
      allowedActions: ['github.fetch_file'],
      expiresAt: '2026-08-17T11:00:00.000Z',
    },
    now,
  );
  const missingClaims = authorizeToolAction('github.fetch_file', undefined, now);
  const expired = authorizeToolAction(
    'github.fetch_file',
    {
      principalId: 'expired-agent',
      allowedActions: ['github.fetch_file'],
      expiresAt: '2026-08-17T09:59:59.000Z',
    },
    now,
  );
  const allowed = authorizeToolAction(
    'github.fetch_file',
    {
      principalId: 'evidence-agent',
      allowedActions: ['github.fetch_file'],
      expiresAt: '2026-08-17T11:00:00.000Z',
    },
    now,
  );

  expect(underlyingActionExecuted).toBe(false);
  expect(denials).toHaveLength(1);
  expect(denied).toMatchObject({ ok: false, code: 'AUTHZ_ACTION_DENIED' });
  expect(missingClaims).toMatchObject({ ok: false, code: 'AUTHZ_INVALID_CLAIMS' });
  expect(expired).toMatchObject({ ok: false, code: 'AUTHZ_EXPIRED' });
  expect(allowed).toEqual({
    ok: true,
    principalId: 'evidence-agent',
    action: 'github.fetch_file',
  });

  const evidence = {
    schemaVersion: 1,
    guardrail: 'tool-action-allowlist',
    certifiedAt: now.toISOString(),
    invariant: 'only explicitly allowlisted tool actions may execute',
    failClosedBeforeExecution: !underlyingActionExecuted,
    denialLogged: denials.length === 1,
    cases: {
      unauthorizedAction: denied,
      missingClaims,
      expiredClaims: expired,
      explicitlyAllowedAction: allowed,
    },
  };

  mkdirSync('test-results', { recursive: true });
  writeFileSync(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
});
