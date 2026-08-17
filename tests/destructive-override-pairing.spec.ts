import { expect, test } from '@playwright/test';
import { pairIrreversibleOperationsWithOverrides } from '../src/guardrails/destructive-override-pairing';

test('pairs only same-file same-scope overrides and marks unmatched operations unannotated', () => {
  const records = pairIrreversibleOperationsWithOverrides(
    [
      { operationId: 'op-delete', file: 'src/a.ts', scope: 'handler>deleteUser', kind: 'delete' },
      { operationId: 'op-drop', file: 'src/a.ts', scope: 'handler>dropTable', kind: 'drop' },
      { operationId: 'op-revoke', file: 'src/b.ts', scope: 'admin>revoke', kind: 'revoke' },
    ],
    [
      { annotationId: 'ov-delete', file: 'src/a.ts', scope: 'handler>deleteUser', operationKinds: ['delete'] },
      { annotationId: 'wrong-scope', file: 'src/a.ts', scope: 'handler', operationKinds: ['drop'] },
      { annotationId: 'wrong-file', file: 'src/c.ts', scope: 'admin>revoke', operationKinds: ['revoke'] },
    ],
  );

  expect(records).toEqual([
    { operationId: 'op-delete', file: 'src/a.ts', scope: 'handler>deleteUser', kind: 'delete', status: 'paired', annotationId: 'ov-delete' },
    { operationId: 'op-drop', file: 'src/a.ts', scope: 'handler>dropTable', kind: 'drop', status: 'unannotated', annotationId: null },
    { operationId: 'op-revoke', file: 'src/b.ts', scope: 'admin>revoke', kind: 'revoke', status: 'unannotated', annotationId: null },
  ]);
});

test('fails closed on ambiguous annotations', () => {
  expect(() => pairIrreversibleOperationsWithOverrides(
    [{ operationId: 'op-1', file: 'src/a.ts', scope: 'f', kind: 'delete' }],
    [
      { annotationId: 'ov-1', file: 'src/a.ts', scope: 'f', operationKinds: ['delete'] },
      { annotationId: 'ov-2', file: 'src/a.ts', scope: 'f', operationKinds: ['delete'] },
    ],
  )).toThrow('AMBIGUOUS_OVERRIDE_ANNOTATION');
});

test('does not pair an annotation that excludes the operation kind', () => {
  const [record] = pairIrreversibleOperationsWithOverrides(
    [{ operationId: 'op-1', file: 'src/a.ts', scope: 'f', kind: 'drop' }],
    [{ annotationId: 'ov-1', file: 'src/a.ts', scope: 'f', operationKinds: ['delete'] }],
  );

  expect(record.status).toBe('unannotated');
  expect(record.annotationId).toBeNull();
});

test('rejects duplicate operation and annotation ids', () => {
  expect(() => pairIrreversibleOperationsWithOverrides(
    [
      { operationId: 'dup', file: 'a', scope: 'f', kind: 'delete' },
      { operationId: 'dup', file: 'a', scope: 'g', kind: 'delete' },
    ],
    [],
  )).toThrow('DUPLICATE_IRREVERSIBLE_OPERATION_ID');

  expect(() => pairIrreversibleOperationsWithOverrides(
    [{ operationId: 'op', file: 'a', scope: 'f', kind: 'delete' }],
    [
      { annotationId: 'dup', file: 'a', scope: 'f' },
      { annotationId: 'dup', file: 'a', scope: 'g' },
    ],
  )).toThrow('DUPLICATE_OVERRIDE_ANNOTATION_ID');
});
