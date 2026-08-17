import { expect, test } from '@playwright/test';
import {
  assertClaimVerifiability,
  validateClaimVerifiability,
} from '../src/guardrails/output-claim-verifiability';

test('rejects unsupported factual claims with claim id and type', () => {
  expect(
    validateClaimVerifiability([
      {
        id: 'claim-1',
        kind: 'fact',
        statement: 'The deployment is healthy.',
      },
    ]),
  ).toEqual({
    ok: false,
    violations: [
      {
        claimId: 'claim-1',
        claimType: 'fact',
        code: 'CLAIM_NOT_VERIFIABLE',
      },
    ],
  });
});

test('rejects vague inference without rationale even when a source is present', () => {
  expect(() =>
    assertClaimVerifiability([
      {
        id: 'claim-2',
        kind: 'inference',
        statement: 'The service is probably stable.',
        sourceRefs: ['runtime-snapshot:42'],
      },
    ]),
  ).toThrow('CLAIM_NOT_VERIFIABLE:claim-2:inference');
});

test('rejects claims without stable ids', () => {
  expect(
    validateClaimVerifiability([
      {
        id: '   ',
        kind: 'metric',
        statement: 'P95 is 4.2s.',
        evidenceRefs: ['metric:latency-p95'],
      },
    ]),
  ).toEqual({
    ok: false,
    violations: [
      {
        claimId: '<missing>',
        claimType: 'metric',
        code: 'CLAIM_ID_MISSING',
      },
    ],
  });
});

test('accepts claims with deterministic evidence or source references', () => {
  expect(
    validateClaimVerifiability([
      {
        id: 'claim-3',
        kind: 'runtime',
        statement: 'The run completed successfully.',
        evidenceRefs: ['builder-run:2091', 'event:owner_finalized'],
      },
      {
        id: 'claim-4',
        kind: 'inference',
        statement: 'The observed failures are consistent with rate limiting.',
        sourceRefs: ['metric:http-429'],
        rationale: 'The failures coincide with recorded HTTP 429 responses.',
      },
    ]),
  ).toEqual({ ok: true });
});
