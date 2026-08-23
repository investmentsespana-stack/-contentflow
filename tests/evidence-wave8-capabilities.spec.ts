import { expect, test } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';
import { createQualityViolation, findDirectStorageInstantiations, handleSecretOrPiiInput, serializeViolation, validateQualityViolation } from '../src/guardrails/evidence-wave8-capabilities';
import { generateClaimRejectionReport } from '../src/guardrails/output-claim-rejection-report';

function walk(dir: string): string[] {
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((entry) => {
    const p = path.join(dir, entry.name);
    return entry.isDirectory() ? walk(p) : [p];
  });
}

test('secret/PII rejection handler returns exact fail-closed code and permits clean input', () => {
  expect(handleSecretOrPiiInput({ hasSecret:true, hasPii:false })).toEqual({ blocked:true, code:'INPUT_CONTAINS_SECRETS_OR_PII' });
  expect(handleSecretOrPiiInput({ hasSecret:false, hasPii:true })).toEqual({ blocked:true, code:'INPUT_CONTAINS_SECRETS_OR_PII' });
  expect(handleSecretOrPiiInput({ hasSecret:false, hasPii:false })).toEqual({ blocked:false });
});

test('production source contains no direct storage-class instantiation', () => {
  const hits = walk('src').filter(p => p.endsWith('.ts')).flatMap(p => findDirectStorageInstantiations(fs.readFileSync(p,'utf8')).map(name => `${p}:${name}`));
  expect(hits).toEqual([]);
  expect(findDirectStorageInstantiations('const x = new PlatformStore();')).toEqual(['PlatformStore']);
});

test('rejection report is real, complete and schema-shaped', () => {
  const report = generateClaimRejectionReport([
    { id:'bad-1', kind:'fact', statement:'Unsupported fact.' },
    { id:'ok-1', kind:'runtime', statement:'Observed.', evidenceRefs:['e:1'] },
  ]);
  expect(report).toEqual({ schemaVersion:'1.0', passed:false, rejectedClaims:[{ claimId:'bad-1', claimType:'fact', code:'CLAIM_NOT_VERIFIABLE', statement:'Unsupported fact.' }] });
});

test('quality violation uses dynamic ISO timestamp and validates schema', () => {
  const v = createQualityViolation('topic_drift','Topic continuity below threshold.',2083,new Date('2026-08-23T04:00:00Z'));
  expect(v.timestamp_utc_iso8601).toBe('2026-08-23T04:00:00.000Z');
  expect(v.timestamp_utc_iso8601).not.toContain('PLACEHOLDER');
  expect(validateQualityViolation(v)).toBe(true);
});

test('quality violation logger emits JSON with every required field', () => {
  const v = createQualityViolation('contradiction','Conflicting statements.',2092,new Date('2026-08-23T04:01:00Z'));
  const parsed = JSON.parse(serializeViolation(v));
  expect(parsed).toEqual(v);
  expect(Object.keys(parsed).sort()).toEqual(['builder_run_id','message','timestamp_utc_iso8601','type']);
});

test('logger serialization is suitable for stdout or stderr transport', () => {
  const line = serializeViolation(createQualityViolation('fragmented_logic','Missing logical bridge.',2116,new Date('2026-08-23T04:02:00Z')));
  expect(() => JSON.parse(line)).not.toThrow();
  expect(line.endsWith('}')).toBe(true);
});
