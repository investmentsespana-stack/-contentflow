import { mkdirSync, writeFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import { validateContractAssumptions } from '../src/guardrails/input-unverified-assumptions';

const evidencePath = 'certification-evidence/input-unverified-assumptions-evidence.json';

test('certifies zero false negatives across 20 deterministic unverified-assumption cases', () => {
  const kinds = ['sanitized', 'trusted_enum', 'trusted_source', 'validated_format'] as const;
  const cases = Array.from({ length: 20 }, (_, index) => {
    const kind = kinds[index % kinds.length];
    const field = `field_${index}`;
    return {
      input: { [field]: `value_${index}` },
      assumptions: [{ field, kind }],
      guarantees: [],
      expectedCode: `UNVERIFIED_ASSUMPTION:${field}:${kind}`,
    };
  });

  let falseNegatives = 0;
  const observed = cases.map((item) => {
    const result = validateContractAssumptions(item.input, item.assumptions, item.guarantees);
    const detected = !result.ok && result.violations.includes(item.expectedCode);
    if (!detected) falseNegatives += 1;
    return { expectedCode: item.expectedCode, detected };
  });

  expect(falseNegatives).toBe(0);
  const evidence = {
    schemaVersion: 1,
    guardrail: 'input-unverified-assumptions',
    caseCount: cases.length,
    falseNegatives,
    falseNegativeRate: falseNegatives / cases.length,
    observed,
  };
  mkdirSync('certification-evidence', { recursive: true });
  writeFileSync(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
});
