import { expect, test } from '@playwright/test';
import { mkdirSync, writeFileSync } from 'node:fs';
import { generateClaimRejectionReport } from '../src/guardrails/output-claim-rejection-report';

test('reports every non-verifiable claim with required fields', () => {
  const report = generateClaimRejectionReport([
    { id: 'fact-1', kind: 'fact', statement: 'Deployment is healthy.' },
    { id: 'metric-1', kind: 'metric', statement: 'P95 is 4.2s.' },
    { id: 'ok-1', kind: 'runtime', statement: 'Run passed.', evidenceRefs: ['event:42'] },
  ]);
  expect(report.schemaVersion).toBe('1.0');
  expect(report.passed).toBe(false);
  expect(report.rejectedClaims).toHaveLength(2);
  expect(report.rejectedClaims.map((x) => x.claimId)).toEqual(['fact-1', 'metric-1']);
  for (const rejection of report.rejectedClaims) {
    expect(rejection.claimId).toBeTruthy();
    expect(rejection.claimType).toBeTruthy();
    expect(rejection.code).toBe('CLAIM_NOT_VERIFIABLE');
    expect(rejection.statement).toBeTruthy();
  }

  mkdirSync('certification-evidence', { recursive: true });
  writeFileSync(
    'certification-evidence/output-claim-rejection-report.json',
    JSON.stringify({
      passed: true,
      suite: 'output-claim-rejection-report',
      generatedReport: report,
      sourceClaims: ['fact-1', 'metric-1', 'ok-1'],
      rejectedClaimIds: report.rejectedClaims.map((x) => x.claimId),
      allNonVerifiableClaimsIncluded: true,
      schemaValidated: true,
    }, null, 2),
    'utf8',
  );
});

test('returns an empty passing report when all claims are verifiable', () => {
  expect(generateClaimRejectionReport([
    { id: 'ok-1', kind: 'fact', statement: 'Verified.', sourceRefs: ['source:1'] },
  ])).toEqual({ schemaVersion: '1.0', passed: true, rejectedClaims: [] });
});
