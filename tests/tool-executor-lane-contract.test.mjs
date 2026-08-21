import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const sql = fs.readFileSync('supabase/migrations/20260820203000_tool_executor_lane_contract_v2.sql','utf8');

test('generic implementation keywords no longer route code into tool_executor', () => {
  assert.match(sql, /else 'llm_artifact'/);
  assert.doesNotMatch(sql, /platformstore\|supabase\|github\|execute\|runtime verification/);
});

test('tool_executor classifier is evidence-specific', () => {
  assert.match(sql, /produce REAL, persisted, correlated evidence/i);
  assert.match(sql, /do not fabricate evidence/i);
});

test('claim accepts ready or blocked executable tool work and moves it to running', () => {
  assert.match(sql, /b\.status in \('blocked','ready'\)/);
  assert.match(sql, /set status='running'/);
  assert.match(sql, /for update of q,b skip locked/);
});

test('finish is fenced by claim token and fails closed', () => {
  assert.match(sql, /state='claimed' and claim_token=p_claim_token/);
  assert.match(sql, /'reason','fenced_out'/);
  assert.match(sql, /set status='blocked'/);
});

test('evidence completion requires runtime verified evidence semantics', () => {
  assert.match(sql, /runtime_verified=true/);
  assert.match(sql, /status=case when is_evidence then 'completed' else 'ready' end/);
  assert.match(sql, /completion_phase=case when is_evidence then 'evidence_verified'/);
});

test('sync repairs old blocked queue deadlock without retrying failed work', () => {
  assert.match(sql, /q\.state='blocked'/);
  assert.match(sql, /set state='pending'/);
  assert.match(sql, /failed_held/);
  assert.doesNotMatch(sql, /q\.state='failed'.*set state='pending'/s);
});
