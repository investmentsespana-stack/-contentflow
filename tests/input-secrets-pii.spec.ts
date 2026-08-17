import { expect, test } from '@playwright/test';
import { assertNoSensitiveInput, scanSensitiveInput } from '../src/guardrails/input-secrets-pii';

test('rejects deterministic secret patterns without returning secret values', () => {
  const result = scanSensitiveInput({ auth: { token: 'Bearer abcdefghijklmnopqrstuvwxyz123456' } });
  expect(result.ok).toBe(false);
  if (!result.ok) {
    expect(result.findings).toEqual([
      { kind: 'secret', pattern: 'bearer_token', path: '$.auth.token' },
    ]);
    expect(JSON.stringify(result)).not.toContain('abcdefghijklmnopqrstuvwxyz123456');
  }
});

test('rejects common PII patterns in nested input', () => {
  const result = scanSensitiveInput({ profile: { email: 'person@example.com', ssn: '123-45-6789' } });
  expect(result.ok).toBe(false);
  if (!result.ok) {
    expect(result.findings).toEqual(
      expect.arrayContaining([
        { kind: 'pii', pattern: 'email', path: '$.profile.email' },
        { kind: 'pii', pattern: 'us_ssn', path: '$.profile.ssn' },
      ]),
    );
  }
});

test('allows clean inputs', () => {
  const clean = { task: 'summarize public release notes', resource_id: 'doc-123', tags: ['public'] };
  expect(scanSensitiveInput(clean)).toEqual({ ok: true, findings: [] });
  expect(() => assertNoSensitiveInput(clean)).not.toThrow();
});

test('assertion rejects sensitive input with deterministic classification only', () => {
  expect(() => assertNoSensitiveInput({ contact: 'person@example.com' })).toThrow(
    'SENSITIVE_INPUT_REJECTED:pii:email@$.contact',
  );
});
