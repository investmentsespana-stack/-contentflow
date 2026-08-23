import { expect, test } from '@playwright/test';
import { captureRejectionEvidence, classifyRejectedInput, detectCoherenceViolations, detectMissingEvidenceCases, enforceRequiredFields, findHighEntropySecrets } from '../src/guardrails/evidence-wave6-capabilities';

test('classifies rejected inputs and captures structured evidence', () => {
  const reason = classifyRejectedInput({ missingFields: ['project_key'] });
  expect(reason).toBe('missing_required_field');
  const ev = captureRejectionEvidence({ foo: 'bar' }, reason, new Date('2026-08-23T00:00:00Z'));
  expect(ev.input_hash).toMatch(/^[a-f0-9]{64}$/);
  expect(ev.timestamp).toBe('2026-08-23T00:00:00.000Z');
  expect(ev.rejection_reason).toBe(reason);
});

test('detects all required coherence violation types with messages', () => {
  const v = detectCoherenceViolations({ topicContinuity: 0.4, contradictionRisk: 0.8, logicalContinuity: 0.5 });
  expect(v.map(x => x.type)).toEqual(['topic_drift','contradiction','fragmented_logic']);
  expect(v.every(x => x.message.length > 0)).toBe(true);
});

test('required fields handler fails closed and allows complete payloads', () => {
  expect(enforceRequiredFields({ project_key: '', task_key: 't' }, ['project_key','task_key'])).toEqual({ status: 400, code: 'MISSING_REQUIRED_FIELDS', missingFields: ['project_key'] });
  expect(enforceRequiredFields({ project_key: 'contentflow', task_key: 't' }, ['project_key','task_key']).status).toBe(200);
});

test('missing evidence detector is exact across 100 known cases', () => {
  const records = Array.from({ length: 100 }, (_, i) => i < 40 ? { id: i, evidence_id: `e-${i}` } : { id: i });
  expect(detectMissingEvidenceCases(records, ['evidence_id'])).toEqual({ total: 100, missing: 60, valid: 40 });
});

test('entropy scanner detects high entropy candidate without returning secret values', () => {
  const findings = findHighEntropySecrets('safe abc abcdef0123456789ZYXWVUTSRQPONMLK');
  expect(findings.length).toBeGreaterThan(0);
  expect(Object.keys(findings[0]).sort()).toEqual(['entropy','tokenLength']);
  expect(JSON.stringify(findings)).not.toContain('abcdef0123456789ZYXWVUTSRQPONMLK');
});
