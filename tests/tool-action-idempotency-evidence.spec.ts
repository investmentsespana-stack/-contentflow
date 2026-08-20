import { mkdirSync, writeFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import {
  assertToolActionIdempotency,
  validateToolActionIdempotency,
} from '../src/guardrails/tool-action-idempotency';

const evidencePath = 'test-results/tool-action-idempotency-evidence.json';

test('certifies tool action idempotency fail-closed behavior and persists deterministic evidence', () => {
  let underlyingActionExecuted = false;
  const denials: unknown[] = [];

  expect(() => {
    assertToolActionIdempotency(
      { action: 'github.delete_file', idempotent: false },
      (entry) => denials.push(entry),
    );
    underlyingActionExecuted = true;
  }).toThrow('NON_IDEMPOTENT_ACTION_DENIED:non_idempotent_action_not_explicitly_permitted');

  const missingMetadata = validateToolActionIdempotency({ action: 'github.create_file' });
  const missingKey = validateToolActionIdempotency({
    action: 'github.update_file',
    idempotent: true,
  });
  const deniedNonIdempotent = validateToolActionIdempotency({
    action: 'supabase.execute_sql',
    idempotent: false,
  });
  const allowedIdempotent = validateToolActionIdempotency({
    action: 'github.update_file',
    idempotent: true,
    idempotencyKey: '  evidence-run:update-file  ',
  });
  const explicitlyPermittedNonIdempotent = validateToolActionIdempotency({
    action: 'github.create_issue',
    idempotent: false,
    explicitlyPermittedNonIdempotent: true,
  });

  expect(underlyingActionExecuted).toBe(false);
  expect(denials).toHaveLength(1);
  expect(missingMetadata).toMatchObject({ ok: false, code: 'IDEMPOTENCY_METADATA_REQUIRED' });
  expect(missingKey).toMatchObject({ ok: false, code: 'IDEMPOTENCY_METADATA_REQUIRED' });
  expect(deniedNonIdempotent).toMatchObject({ ok: false, code: 'NON_IDEMPOTENT_ACTION_DENIED' });
  expect(allowedIdempotent).toEqual({
    ok: true,
    action: 'github.update_file',
    idempotent: true,
    idempotencyKey: 'evidence-run:update-file',
    explicitlyPermittedNonIdempotent: false,
  });
  expect(explicitlyPermittedNonIdempotent).toEqual({
    ok: true,
    action: 'github.create_issue',
    idempotent: false,
    explicitlyPermittedNonIdempotent: true,
  });

  const evidence = {
    schemaVersion: 1,
    guardrail: 'tool-action-idempotency',
    invariant: 'tool actions must declare safe idempotency semantics before execution',
    failClosedBeforeExecution: !underlyingActionExecuted,
    denialLogged: denials.length === 1,
    cases: {
      missingMetadata,
      missingIdempotencyKey: missingKey,
      deniedNonIdempotent,
      allowedIdempotent,
      explicitlyPermittedNonIdempotent,
    },
  };

  mkdirSync('test-results', { recursive: true });
  writeFileSync(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
});
