import { expect, test } from '@playwright/test';
import {
  assertContractAssumptions,
  validateContractAssumptions,
} from '../src/guardrails/input-unverified-assumptions';

test('rejects reliance on sanitization not guaranteed by the contract', () => {
  const result = validateContractAssumptions(
    { prompt: '<script>alert(1)</script>' },
    [{ field: 'prompt', kind: 'sanitized' }],
    [],
  );

  expect(result).toEqual({
    ok: false,
    violations: ['UNVERIFIED_ASSUMPTION:prompt:sanitized'],
  });
});

test('rejects trusted enum assumptions when the contract does not guarantee them', () => {
  expect(() =>
    assertContractAssumptions(
      { lane: 'production' },
      [{ field: 'lane', kind: 'trusted_enum' }],
      [{ field: 'lane', kind: 'validated_format' }],
    ),
  ).toThrow('UNVERIFIED_ASSUMPTION:lane:trusted_enum');
});

test('rejects assumptions for fields that are not present in the input', () => {
  expect(
    validateContractAssumptions(
      {},
      [{ field: 'source', kind: 'trusted_source' }],
      [{ field: 'source', kind: 'trusted_source' }],
    ),
  ).toEqual({
    ok: false,
    violations: ['ASSUMPTION_FIELD_MISSING:source:trusted_source'],
  });
});

test('allows only assumptions explicitly guaranteed by the interface contract', () => {
  expect(
    validateContractAssumptions(
      { lane: 'qa', prompt: 'safe' },
      [
        { field: 'lane', kind: 'trusted_enum' },
        { field: 'prompt', kind: 'sanitized' },
      ],
      [
        { field: 'lane', kind: 'trusted_enum' },
        { field: 'prompt', kind: 'sanitized' },
      ],
    ),
  ).toEqual({ ok: true });
});
