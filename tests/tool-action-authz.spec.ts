import { expect, test } from '@playwright/test';
import { assertToolActionAuthorized, authorizeToolAction } from '../src/guardrails/tool-action-authz';

const now = new Date('2026-08-17T10:00:00.000Z');

test('rejects an action before execution when atomic claims do not authorize it', () => {
  const decision = authorizeToolAction(
    'github.delete_file',
    {
      principalId: 'agent-1',
      allowedActions: ['github.fetch_file'],
      expiresAt: '2026-08-17T11:00:00.000Z',
    },
    now,
  );

  expect(decision).toEqual({
    ok: false,
    code: 'AUTHZ_ACTION_DENIED',
    reason: 'action_not_authorized:github.delete_file',
    principalId: 'agent-1',
    action: 'github.delete_file',
  });
});

test('logs the denial reason and throws before the caller can execute the action', () => {
  const denials: unknown[] = [];

  expect(() =>
    assertToolActionAuthorized(
      'supabase.execute_sql',
      { principalId: 'agent-2', allowedActions: [] },
      (entry) => denials.push(entry),
      now,
    ),
  ).toThrow('AUTHZ_ACTION_DENIED:action_not_authorized:supabase.execute_sql');

  expect(denials).toHaveLength(1);
  expect(denials[0]).toMatchObject({
    code: 'AUTHZ_ACTION_DENIED',
    reason: 'action_not_authorized:supabase.execute_sql',
    principalId: 'agent-2',
  });
});

test('rejects missing or expired claims', () => {
  expect(authorizeToolAction('github.fetch_file', undefined, now)).toMatchObject({
    ok: false,
    code: 'AUTHZ_INVALID_CLAIMS',
  });

  expect(
    authorizeToolAction(
      'github.fetch_file',
      {
        principalId: 'agent-3',
        allowedActions: ['github.fetch_file'],
        expiresAt: '2026-08-17T09:59:59.000Z',
      },
      now,
    ),
  ).toMatchObject({ ok: false, code: 'AUTHZ_EXPIRED' });
});

test('allows only an explicitly authorized action', () => {
  expect(
    authorizeToolAction(
      'github.fetch_file',
      {
        principalId: 'agent-4',
        allowedActions: ['github.fetch_file', 'supabase.execute_sql'],
        expiresAt: '2026-08-17T11:00:00.000Z',
      },
      now,
    ),
  ).toEqual({ ok: true, principalId: 'agent-4', action: 'github.fetch_file' });
});
