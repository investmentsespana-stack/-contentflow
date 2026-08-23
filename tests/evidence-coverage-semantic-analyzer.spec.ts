import { expect, test } from '@playwright/test';
import { buildEvidenceCoveragePlan } from '../src/evidence/evidence-coverage-planner';
import {
  analyzeJsonSchema,
  analyzeSqlStatements,
  analyzeTypeScriptExports,
} from '../src/evidence/semantic-evidence-analyzer';

test('coverage planner prioritizes verifiable and producer-backed requirements deterministically', () => {
  const plan = buildEvidenceCoveragePlan(
    [
      { id: 1, requirementClass: 'runtime_test', prerequisite: 'runtime_test', taskKey: 'a' },
      { id: 2, requirementClass: 'source_contract', prerequisite: 'source_contract', taskKey: 'b' },
      { id: 3, requirementClass: 'static_analysis', prerequisite: 'unknown', taskKey: 'c' },
    ],
    [
      {
        prerequisite: 'runtime_test',
        verifierAvailable: true,
        producerAvailable: true,
        provider: 'ci',
      },
      {
        prerequisite: 'source_contract',
        verifierAvailable: true,
        producerAvailable: false,
        evidenceAlreadyVerifiable: true,
        provider: 'repo',
      },
    ],
  );

  expect(plan.map((item) => [item.id, item.state])).toEqual([
    [1, 'producer_ready'],
    [2, 'ready_to_verify'],
    [3, 'missing_capability'],
  ]);
});

test('semantic analyzer validates TypeScript exports structurally, not by keyword occurrence', () => {
  const source = `
    // function fakeName() in a comment must not count
    export interface PlatformStore { recordEvidence(input: unknown): Promise<void> }
    export function checkApproval(record: unknown, context: unknown) { return Boolean(record && context); }
    const text = 'export function injected() {}';
  `;

  expect(
    analyzeTypeScriptExports(source, [
      { name: 'PlatformStore', kind: 'interface' },
      { name: 'checkApproval', kind: 'function', minParameters: 2 },
    ]).passed,
  ).toBe(true);
  expect(analyzeTypeScriptExports(source, [{ name: 'injected', kind: 'function' }]).passed).toBe(false);
});

test('semantic analyzer validates JSON Schema property structure and required membership', () => {
  const schema = JSON.stringify({
    type: 'object',
    properties: { timestamp: { type: 'string' }, payload_hash: { type: 'string' } },
    required: ['timestamp', 'payload_hash'],
  });

  expect(analyzeJsonSchema(schema, ['timestamp', 'payload_hash']).passed).toBe(true);
  expect(analyzeJsonSchema(schema, ['storage_location']).passed).toBe(false);
});

test('SQL analysis is statement-aware for multiline DELETE and fails closed on destructive statements', () => {
  const safe = `DELETE FROM public.example\nWHERE id = 1; SELECT 1;`;
  const unsafe = `DELETE FROM public.example; TRUNCATE public.audit;`;

  expect(analyzeSqlStatements(safe).passed).toBe(true);
  expect(analyzeSqlStatements(unsafe).passed).toBe(false);
});
