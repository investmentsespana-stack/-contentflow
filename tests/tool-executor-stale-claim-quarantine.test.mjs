import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const sql=fs.readFileSync('supabase/migrations/20260820203800_tool_executor_stale_claim_quarantine.sql','utf8');

test('off-lane claimed work is quarantined and token revoked',()=>{
  assert.match(sql,/q\.state='claimed'/);
  assert.match(sql,/b\.execution_lane<>'tool_executor'/);
  assert.match(sql,/b\.status<>'running'/);
  assert.match(sql,/claim_token=null/);
  assert.match(sql,/claimed_at=null/);
  assert.match(sql,/QUARANTINED_OFF_LANE_STALE_CLAIM/);
});

test('active running backlog is explicitly protected',()=>{
  assert.match(sql,/b\.status<>'running'/);
});
