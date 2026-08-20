import { mkdirSync, writeFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import {
  analyzeDestructiveAst,
  assertDestructiveCallsAreIdempotent,
  type AstNode,
} from '../src/guardrails/destructive-idempotency-ast';
import { pairIrreversibleOperationsWithOverrides } from '../src/guardrails/destructive-override-pairing';

const evidencePath = 'certification-evidence/destructive-action-safety-evidence.json';

test('certifies destructive action safety invariants and persists deterministic evidence', () => {
  const protectedAst: AstNode = {
    type: 'program',
    file: 'runtime/safe.ts',
    children: [
      {
        type: 'function',
        name: 'process_with_idempotency',
        children: [
          { type: 'call', callee: 'store.delete', line: 10 },
          { type: 'call', callee: 'db.truncate', line: 11 },
        ],
      },
    ],
  };

  const unsafeAst: AstNode = {
    type: 'program',
    file: 'runtime/unsafe.ts',
    children: [
      {
        type: 'function',
        name: 'deploy_change',
        children: [{ type: 'call', callee: 'db.drop', line: 41 }],
      },
    ],
  };

  const protectedReport = assertDestructiveCallsAreIdempotent(protectedAst);
  const unsafeReport = analyzeDestructiveAst(unsafeAst);
  expect(protectedReport.zero_violations).toBe(true);
  expect(unsafeReport.zero_violations).toBe(false);
  expect(() => assertDestructiveCallsAreIdempotent(unsafeAst)).toThrow(/DESTRUCTIVE_IDEMPOTENCY_VIOLATION/);

  const pairing = pairIrreversibleOperationsWithOverrides(
    [
      { operationId: 'delete-user', file: 'src/admin.ts', scope: 'handler>deleteUser', kind: 'delete' },
      { operationId: 'drop-table', file: 'src/admin.ts', scope: 'handler>dropTable', kind: 'drop' },
    ],
    [
      { annotationId: 'override-delete', file: 'src/admin.ts', scope: 'handler>deleteUser', operationKinds: ['delete'] },
      { annotationId: 'wrong-scope', file: 'src/admin.ts', scope: 'handler', operationKinds: ['drop'] },
    ],
  );

  expect(pairing).toEqual([
    {
      operationId: 'delete-user',
      file: 'src/admin.ts',
      scope: 'handler>deleteUser',
      kind: 'delete',
      status: 'paired',
      annotationId: 'override-delete',
    },
    {
      operationId: 'drop-table',
      file: 'src/admin.ts',
      scope: 'handler>dropTable',
      kind: 'drop',
      status: 'unannotated',
      annotationId: null,
    },
  ]);

  expect(() =>
    pairIrreversibleOperationsWithOverrides(
      [{ operationId: 'ambiguous', file: 'src/a.ts', scope: 'f', kind: 'delete' }],
      [
        { annotationId: 'ov-1', file: 'src/a.ts', scope: 'f', operationKinds: ['delete'] },
        { annotationId: 'ov-2', file: 'src/a.ts', scope: 'f', operationKinds: ['delete'] },
      ],
    ),
  ).toThrow('AMBIGUOUS_OVERRIDE_ANNOTATION');

  const evidence = {
    schemaVersion: 1,
    guardrail: 'destructive-action-safety',
    invariant: 'destructive calls require idempotent lexical protection and irreversible overrides must pair exactly',
    cases: {
      protectedDestructiveCalls: protectedReport,
      unsafeDestructiveCallDetected: unsafeReport,
      overridePairing: pairing,
      ambiguousOverrideFailsClosed: true,
    },
  };

  mkdirSync('certification-evidence', { recursive: true });
  writeFileSync(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
});
