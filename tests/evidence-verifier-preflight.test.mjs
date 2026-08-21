import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const sql=fs.readFileSync('supabase/migrations/20260820204100_evidence_verifier_preflight_gate.sql','utf8');

test('verifier claim requires deterministic preflight',()=>{
  assert.match(sql,/contentflow_evidence_verifier_preflight/);
  assert.match(sql,/and public\.contentflow_evidence_verifier_preflight\(p_project_key,q\.task_key\)/);
});

test('unverifiable pending work is held without burning attempts',()=>{
  assert.match(sql,/WAITING_FOR_EVIDENCE_PRODUCER/);
  assert.match(sql,/q\.state='pending'/);
  assert.doesNotMatch(sql,/WAITING_FOR_EVIDENCE_PRODUCER[\s\S]{0,250}attempts\s*=\s*attempts\+1/);
});

test('evidence-not-available failures only recover when preflight becomes true',()=>{
  assert.match(sql,/q\.state='failed'/);
  assert.match(sql,/EVIDENCE_NOT_AVAILABLE:%/);
  assert.match(sql,/recovered_failed/);
});
