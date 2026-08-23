import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const root = fs.readFileSync('supabase/migrations/20260823115000_evidence_reconciler_root_hardening_v1.sql','utf8');
const reconcile = fs.readFileSync('supabase/migrations/20260823115100_evidence_first_reconcile_v2.sql','utf8');
const privileges = fs.readFileSync('supabase/migrations/20260823115200_evidence_reconciler_rpc_privilege_hardening.sql','utf8');

test('evidence identity is stable and certified source correlation is immutable', () => {
  assert.match(reconcile, /md5\(lower\(x\.task_key\)\|\|'\|'\|\|v_cls\)/);
  assert.match(reconcile, /v_existing_status='verified'.*continue/s);
  assert.doesNotMatch(reconcile, /regexp_replace\(lower\(left\(coalesce\(x\.error/);
});

test('generic approval word does not force external approval', () => {
  assert.match(root, /end-to-end test\|e2e test/);
  assert.match(root, /human\|owner\|security team\|architecture team\|external/);
  assert.doesNotMatch(root, /~\* 'approval\|security team\|architecture team'/);
});

test('orphan evidence dependencies have deterministic garbage collection', () => {
  assert.match(root, /contentflow_gc_evidence_dependencies/);
  assert.match(root, /orphan_evidence_retired/);
  assert.match(root, /evidence_verified/);
});

test('mutating reconciler RPCs are service-role only', () => {
  for (const fn of ['contentflow_gc_evidence_dependencies','contentflow_reconcile_ready_after_evidence','contentflow_evidence_first_reconcile']) {
    assert.match(privileges, new RegExp(`revoke all on function public\\.${fn}`));
    assert.match(privileges, new RegExp(`grant execute on function public\\.${fn}.*service_role`));
  }
});
