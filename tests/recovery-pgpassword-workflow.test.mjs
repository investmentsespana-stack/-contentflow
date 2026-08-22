import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';

const snapshot=fs.readFileSync('.github/workflows/daily-recovery-snapshot.yml','utf8');
const probe=fs.readFileSync('.github/workflows/recovery-diagnostic-probe.yml','utf8');
const resolver=fs.readFileSync('.github/scripts/resolve-recovery-db-password.py','utf8');

test('canonical recovery uses Session Pooler with PGPASSWORD, not reconstructed password URI',()=>{
  assert.match(snapshot,/PGPASSWORD/);
  assert.match(snapshot,/aws-0-us-east-1\.pooler\.supabase\.com/);
  assert.match(snapshot,/postgres\.koqpyfvnprmirqviafzq/);
  assert.doesNotMatch(snapshot,/POOLER_URL=/);
});

test('resolver supports dedicated password secret and legacy raw or percent-decoded compatibility',()=>{
  assert.match(resolver,/SUPABASE_DB_PASSWORD/);
  assert.match(resolver,/legacy_raw/);
  assert.match(resolver,/legacy_percent_decoded/);
  assert.match(resolver,/PGPASSWORD/);
});

test('diagnostic never persists raw postgres stderr or credential material',()=>{
  assert.match(probe,/credential_source/);
  assert.doesNotMatch(probe,/cat \/tmp\/pooler\.err/);
  assert.doesNotMatch(probe,/echo \"\$PGPASSWORD\"/);
});
