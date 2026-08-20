import { expect, test } from '@playwright/test';
import { claimsFromProjectPolicy } from '../src/guardrails/project-authorization-policy';
import { authorizeToolAction } from '../src/guardrails/tool-action-authz';

const now = new Date('2026-08-20T15:00:00.000Z');

test('central authorization semantics preserve project-scoped capabilities', () => {
  const claims = claimsFromProjectPolicy('contentflow', {
    projectId: 'contentflow',
    principalId: 'contentflow-agent',
    allowedActions: ['github.fetch_file'],
    expiresAt: '2026-08-20T16:00:00.000Z',
  });

  expect(authorizeToolAction('github.fetch_file', claims, now)).toMatchObject({ ok: true });
  expect(authorizeToolAction('github.delete_file', claims, now)).toMatchObject({
    ok: false,
    code: 'AUTHZ_ACTION_DENIED',
  });
});

test('a project policy cannot mint claims across project boundaries', () => {
  const claims = claimsFromProjectPolicy('opc', {
    projectId: 'contentflow',
    principalId: 'contentflow-agent',
    allowedActions: ['github.fetch_file'],
  });

  expect(claims).toBeUndefined();
  expect(authorizeToolAction('github.fetch_file', claims, now)).toMatchObject({
    ok: false,
    code: 'AUTHZ_INVALID_CLAIMS',
  });
});
