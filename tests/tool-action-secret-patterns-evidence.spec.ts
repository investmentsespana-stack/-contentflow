import { mkdirSync, writeFileSync } from 'node:fs';
import { expect, test } from '@playwright/test';
import {
  assertNoToolActionSecrets,
  scanToolActionSecrets,
} from '../src/guardrails/tool-action-secret-patterns';

const evidencePath = 'test-results/tool-action-secret-patterns-evidence.json';
const certifiedAt = '2026-08-20T15:45:00.000Z';

test('certifies tool action secret-pattern enforcement and persists deterministic evidence', () => {
  let underlyingActionExecuted = false;

  const syntheticSecret = 'ghp_123456789012345678901234567890123456';
  const findings = scanToolActionSecrets(
    {
      action: 'github.update_file',
      token: syntheticSecret,
      nested: { bearer: 'Bearer abcdefghijklmnopqrstuvwxyz0123456789' },
    },
    { status: 'blocked' },
  );

  expect(findings.length).toBeGreaterThan(0);
  expect(findings.map((entry) => entry.pattern)).toEqual(
    expect.arrayContaining(['github_token', 'bearer_token']),
  );
  expect(JSON.stringify(findings)).not.toContain(syntheticSecret);

  expect(() => {
    assertNoToolActionSecrets(
      { password: 'password=abcdefghijklmnopqrstuvwxyz123456' },
      null,
    );
    underlyingActionExecuted = true;
  }).toThrow('TOOL_ACTION_SECRET_REJECTED');

  expect(underlyingActionExecuted).toBe(false);

  const cleanFindings = scanToolActionSecrets(
    { action: 'github.update_file', path: 'src/index.ts' },
    { ok: true, status: 'updated' },
  );
  expect(cleanFindings).toEqual([]);

  const corpus: string[] = [];
  for (let i = 0; i < 500; i += 1) {
    const suffix = i.toString(36).toUpperCase().padStart(16, 'A').slice(-16);
    corpus.push(`AKIA${suffix}`);
    corpus.push(`ghp_${i.toString(36).padStart(36, 'a')}`);
    corpus.push(`sk-${i.toString(36).padStart(36, 'b')}`);
    corpus.push(`github_pat_${i.toString(36).padStart(32, 'c')}`);
  }

  let missed = 0;
  for (const secret of corpus) {
    if (scanToolActionSecrets({ secret }, null).length === 0) missed += 1;
  }
  const falseNegativeRate = missed / corpus.length;
  expect(falseNegativeRate).toBeLessThan(0.001);

  const evidence = {
    schemaVersion: 1,
    guardrail: 'tool-action-secret-patterns',
    certifiedAt,
    invariant: 'tool actions containing detected secrets are rejected before execution and findings never expose secret values',
    failClosedBeforeExecution: !underlyingActionExecuted,
    secretValuesRedacted: !JSON.stringify(findings).includes(syntheticSecret),
    cleanPayloadAllowed: cleanFindings.length === 0,
    representativeCorpusSize: corpus.length,
    representativeCorpusMissed: missed,
    falseNegativeRate,
    detectedPatterns: [...new Set(findings.map((entry) => entry.pattern))].sort(),
  };

  mkdirSync('test-results', { recursive: true });
  writeFileSync(evidencePath, `${JSON.stringify(evidence, null, 2)}\n`, 'utf8');
});
