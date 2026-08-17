import { test, expect } from '@playwright/test';
import {
  analyzeDestructiveAst,
  assertDestructiveCallsAreIdempotent,
  type AstNode,
} from '../src/guardrails/destructive-idempotency-ast';

test('all destructive calls inside process_with_idempotency produce compliant mappings', () => {
  const ast: AstNode = {
    type: 'program',
    file: 'runtime/destructive-actions.ts',
    children: [
      {
        type: 'function',
        name: 'process_with_idempotency',
        children: [
          { type: 'call', callee: 'store.delete', line: 18 },
          { type: 'call', callee: 'cache.remove', line: 22 },
          { type: 'call', callee: 'db.truncate', line: 27 },
        ],
      },
    ],
  };

  const report = assertDestructiveCallsAreIdempotent(ast);
  expect(report.zero_violations).toBe(true);
  expect(report.violations).toEqual([]);
  expect(report.compliant_mappings).toHaveLength(3);
  expect(report.compliant_mappings.every((m) => m.protected_by === 'process_with_idempotency')).toBe(true);
  expect(report.compliant_mappings).toEqual([
    expect.objectContaining({ line: 18, callee: 'store.delete', protected_by: 'process_with_idempotency' }),
    expect.objectContaining({ line: 22, callee: 'cache.remove', protected_by: 'process_with_idempotency' }),
    expect.objectContaining({ line: 27, callee: 'db.truncate', protected_by: 'process_with_idempotency' }),
  ]);
});

test('destructive call outside process_with_idempotency is a hard violation', () => {
  const ast: AstNode = {
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

  const report = analyzeDestructiveAst(ast);
  expect(report.zero_violations).toBe(false);
  expect(report.compliant_mappings).toEqual([]);
  expect(report.violations).toEqual([
    {
      file: 'runtime/unsafe.ts',
      line: 41,
      callee: 'db.drop',
      reason: 'destructive_call_outside_process_with_idempotency',
    },
  ]);
  expect(() => assertDestructiveCallsAreIdempotent(ast)).toThrow(/DESTRUCTIVE_IDEMPOTENCY_VIOLATION/);
});

test('nested helper remains protected when lexical function context includes process_with_idempotency', () => {
  const ast: AstNode = {
    type: 'program',
    file: 'runtime/nested.ts',
    children: [
      {
        type: 'function',
        name: 'process_with_idempotency',
        children: [
          {
            type: 'function',
            name: 'work_func',
            children: [{ type: 'call', callee: 'resource.destroy', line: 9 }],
          },
        ],
      },
    ],
  };

  const report = assertDestructiveCallsAreIdempotent(ast);
  expect(report.zero_violations).toBe(true);
  expect(report.compliant_mappings).toEqual([
    {
      file: 'runtime/nested.ts',
      line: 9,
      callee: 'resource.destroy',
      protected_by: 'process_with_idempotency',
    },
  ]);
});
