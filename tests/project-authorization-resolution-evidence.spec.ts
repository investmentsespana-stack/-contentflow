import { mkdirSync, writeFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import { claimsFromProjectPolicy } from '../src/guardrails/project-authorization-policy';
import { authorizeToolAction } from '../src/guardrails/tool-action-authz';

const evidencePath = 'certification-evidence/project-authorization-resolution-evidence.json';
const now = new Date('2026-08-20T15:00:00.000Z');

test('certifies five distinct atomic-claims resolution patterns and integration with authorization', () => {
  const cases = [
    {
      name: 'valid_project_policy',
      claims: claimsFromProjectPolicy('contentflow', { projectId: 'contentflow', principalId: 'a1', allowedActions: ['github.fetch_file'], expiresAt: '2026-08-20T16:00:00.000Z' }),
      expected: 'allow',
    },
    {
      name: 'cross_project_rejected',
      claims: claimsFromProjectPolicy('contentflow', { projectId: 'opc', principalId: 'a2', allowedActions: ['github.fetch_file'] }),
      expected: 'invalid',
    },
    {
      name: 'missing_principal_rejected',
      claims: claimsFromProjectPolicy('contentflow', { projectId: 'contentflow', principalId: '   ', allowedActions: ['github.fetch_file'] }),
      expected: 'invalid',
    },
    {
      name: 'explicit_denial',
      claims: claimsFromProjectPolicy('contentflow', { projectId: 'contentflow', principalId: 'a4', allowedActions: [] }),
      expected: 'deny',
    },
    {
      name: 'expired_claims',
      claims: claimsFromProjectPolicy('contentflow', { projectId: 'contentflow', principalId: 'a5', allowedActions: ['github.fetch_file'], expiresAt: '2026-08-20T14:59:59.000Z' }),
      expected: 'expired',
    },
  ];

  const observed = cases.map((item) => {
    const decision = authorizeToolAction('github.fetch_file', item.claims, now);
    if (item.expected === 'allow') expect(decision).toMatchObject({ ok: true });
    if (item.expected === 'invalid') expect(decision).toMatchObject({ ok: false, code: 'AUTHZ_INVALID_CLAIMS' });
    if (item.expected === 'deny') expect(decision).toMatchObject({ ok: false, code: 'AUTHZ_ACTION_DENIED' });
    if (item.expected === 'expired') expect(decision).toMatchObject({ ok: false, code: 'AUTHZ_EXPIRED' });
    return { name: item.name, expected: item.expected, decision };
  });

  mkdirSync('certification-evidence', { recursive: true });
  writeFileSync(evidencePath, `${JSON.stringify({ schemaVersion: 1, caseCount: cases.length, observed }, null, 2)}\n`, 'utf8');
});
