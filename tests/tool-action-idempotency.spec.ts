import { expect, test } from '@playwright/test';
import {
  assertToolActionIdempotency,
  validateToolActionIdempotency,
} from '../src/guardrails/tool-action-idempotency';

test('rejects an allowed action when idempotency metadata is missing', () => {
  expect(
    validateToolActionIdempotency({ action: 'github.create_file' }),
  ).toEqual({
    ok: false,
    code: 'IDEMPOTENCY_METADATA_REQUIRED',
    reason: 'action_must_declare_idempotency',
    action: 'github.create_file',
  });
});

test('rejects non-idempotent actions unless explicitly permitted', () => {
  expect(
    validateToolActionIdempotency({
      action: 'supabase.execute_sql',
      idempotent: false,
    }),
  ).toEqual({
    ok: false,
    code: 'NON_IDEMPOTENT_ACTION_DENIED',
    reason: 'non_idempotent_action_not_explicitly_permitted',
    action: 'supabase.execute_sql',
  });
});

test('requires an idempotency key for idempotent actions', () => {
  expect(
    validateToolActionIdempotency({
      action: 'github.update_file',
      idempotent: true,
    }),
  ).toMatchObject({
    ok: false,
    code: 'IDEMPOTENCY_METADATA_REQUIRED',
  });
});

test('returns normalized idempotency metadata for allowed idempotent actions', () => {
  expect(
    validateToolActionIdempotency({
      action: 'github.update_file',
      idempotent: true,
      idempotencyKey: '  run-42:update-config  ',
    }),
  ).toEqual({
    ok: true,
    action: 'github.update_file',
    idempotent: true,
    idempotencyKey: 'run-42:update-config',
    explicitlyPermittedNonIdempotent: false,
  });
});

test('allows a non-idempotent action only with an explicit permit', () => {
  expect(
    validateToolActionIdempotency({
      action: 'github.create_issue',
      idempotent: false,
      explicitlyPermittedNonIdempotent: true,
    }),
  ).toEqual({
    ok: true,
    action: 'github.create_issue',
    idempotent: false,
    explicitlyPermittedNonIdempotent: true,
  });
});

test('logs and blocks invalid metadata before execution', () => {
  const denials: unknown[] = [];

  expect(() =>
    assertToolActionIdempotency(
      { action: 'github.delete_file', idempotent: false },
      (entry) => denials.push(entry),
    ),
  ).toThrow('NON_IDEMPOTENT_ACTION_DENIED:non_idempotent_action_not_explicitly_permitted');

  expect(denials).toHaveLength(1);
  expect(denials[0]).toMatchObject({
    action: 'github.delete_file',
    code: 'NON_IDEMPOTENT_ACTION_DENIED',
  });
});
