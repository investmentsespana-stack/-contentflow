import { expect, test } from '@playwright/test';
import { assertRequiredFields, validateRequiredFields } from '../src/guardrails/input-required-fields';

test('rejects when any required field is absent', () => {
  expect(validateRequiredFields({ task: 'x' }, ['task', 'resource_id'])).toEqual({
    ok: false,
    missing: ['resource_id'],
  });
  expect(() => assertRequiredFields({ task: 'x' }, ['task', 'resource_id'])).toThrow(
    'MISSING_REQUIRED_FIELDS:resource_id',
  );
});

test('rejects null or undefined required values deterministically', () => {
  expect(validateRequiredFields({ task: null, resource_id: undefined }, ['task', 'resource_id'])).toEqual({
    ok: false,
    missing: ['task', 'resource_id'],
  });
});

test('allows payloads containing all required fields', () => {
  expect(validateRequiredFields({ task: '', resource_id: 'r1', extra: true }, ['task', 'resource_id'])).toEqual({
    ok: true,
  });
  expect(() => assertRequiredFields({ task: '', resource_id: 'r1' }, ['task', 'resource_id'])).not.toThrow();
});
