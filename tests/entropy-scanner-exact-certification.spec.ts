import { expect, test } from '@playwright/test';
import { findHighEntropySecrets } from '../src/guardrails/evidence-wave6-capabilities';

const syntheticHighEntropyCorpus = [
  'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdef',
  '0123456789ABCDEFGHIJKLMNOPQRSTUV',
  'aB3dE5gH7jK9mN2pQ4sT6vW8xY0zC1F2',
  'ZYXWVUTSRQPONMLKJIHGFEDCBA987654',
] as const;

const knownSyntheticSecretSamples = [
  'sk_TEST_4F7aB9cD2eG6hJ8kL1mN3pQ5rS7tV9xZ',
  'tok_TEST_A1b2C3d4E5f6G7h8I9j0KLMNOPQRSTUV',
  'key_TEST_Z9y8X7w6V5u4T3s2R1q0PONMLKJIHGFE',
] as const;

test('flags every synthetic token whose measured entropy is at least 4.5 bits per character', () => {
  for (const token of syntheticHighEntropyCorpus) {
    const findings = findHighEntropySecrets(`prefix ${token} suffix`, 20, 4.5);
    expect(findings, `expected high-entropy token length=${token.length} to be detected`).toHaveLength(1);
    expect(findings[0].entropy).toBeGreaterThanOrEqual(4.5);
    expect(findings[0].tokenLength).toBe(token.length);
  }
});

test('has zero false negatives on the known synthetic secret corpus and never returns secret values', () => {
  let detected = 0;
  for (const token of knownSyntheticSecretSamples) {
    const findings = findHighEntropySecrets(token, 20, 4.5);
    if (findings.length > 0) detected += 1;
    expect(JSON.stringify(findings)).not.toContain(token);
    expect(findings.every((item) => Object.keys(item).sort().join(',') === 'entropy,tokenLength')).toBe(true);
  }
  expect(detected).toBe(knownSyntheticSecretSamples.length);
});
