import { test, expect } from '@playwright/test';
import { FORMAT_VIOLATION_CONDITIONS, classifyFormatViolation } from '../src/guardrails/input-format-violations';

test('all canonical syntax and structure failures map to format_violation with spec rationale', () => {
  const expected = [
    'malformed_json',
    'root_not_object',
    'invalid_uuid_format',
    'invalid_iso8601_timestamp',
    'wrong_scalar_type',
    'wrong_container_type',
    'invalid_array_item_shape',
    'invalid_encoded_string_format',
  ];

  expect(FORMAT_VIOLATION_CONDITIONS.map((condition) => condition.id)).toEqual(expected);
  for (const condition of FORMAT_VIOLATION_CONDITIONS) {
    expect(condition.category).toBe('format_violation');
    expect(condition.rule).toMatch(/^IFR-00[1-8]:/);
    expect(condition.rationale).toContain('format_violation');
    expect(condition.rationale).toContain(condition.rule.slice(0, 7));
    expect(classifyFormatViolation(condition.id)).toEqual(condition);
  }
});

test('unknown or semantic conditions are not silently classified as format violations', () => {
  expect(classifyFormatViolation('missing_required_field')).toBeNull();
  expect(classifyFormatViolation('secret_exposure')).toBeNull();
  expect(classifyFormatViolation('unwarranted_assumption')).toBeNull();
  expect(classifyFormatViolation('domain_constraint')).toBeNull();
  expect(classifyFormatViolation('unknown')).toBeNull();
});
