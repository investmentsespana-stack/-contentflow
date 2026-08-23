import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';

const migration = await readFile('supabase/migrations/20260823033000_ci_runtime_evidence_bridge_v2.sql', 'utf8');

test('source-contract is an explicit allowlisted CI profile', () => {
  assert.match(migration, /'source-contract'/);
  assert.match(migration, /'source_contract'/);
});

test('source-contract evidence only verifies source_contract requirements', () => {
  assert.match(migration, /er\.requirement_class='source_contract' and x\.evidence_type='source_contract'/);
});

test('bridge remains correlated and privileged', () => {
  assert.match(migration, /requirement_correlation_mismatch/);
  assert.match(migration, /privileged_ci_channel_required/);
  assert.match(migration, /passing_nonempty_payload_required/);
});
