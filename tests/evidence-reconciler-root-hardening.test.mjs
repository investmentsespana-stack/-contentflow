import assert from 'node:assert/strict';
import fs from 'node:fs';
import test from 'node:test';

const root = fs.readFileSync('supabase/migrations/20260823115000_evidence_reconciler_root_hardening_v1.sql','utf8');
const reconcile = fs.readFileSync('supabase/migrations/20260823115100_evidence_first_reconcile_v2.sql','utf8');
const reconcileV21 = fs.readFileSync('supabase/migrations/20260823121500_evidence_first_reconcile_v2_1_idempotence.sql','utf8');
const privileges = fs.readFileSync('supabase/migrations/20260823115200_evidence_reconciler_rpc_privilege_hardening.sql','utf8');

test('evidence identity is stable and certified source correlation is immutable', () => {
  assert.match(reconcile, /md5\(lower\(x\.task_key\)\|\|'\|'\|\|v_cls\)/);
  assert.match(reconcileV21, /v_existing_status='verified'.*continue/s);
  assert.doesNotMatch(reconcileV21, /regexp_replace\(lower\(left\(coalesce\(x\.error/);
});

test('V2.1 reuses the persisted harness identity and only holds on real state change', () => {
  assert.match(reconcileV21, /v_existing_evidence_key/);
  assert.match(reconcileV21, /v_evidence_key:=v_existing_evidence_key/);
  assert.match(reconcileV21, /depends_on is distinct from v_new_dep/);
  assert.match(reconcileV21, /if found then v_held:=v_held\+1/);
  assert.match(reconcileV21, /EVIDENCE_FIRST_EXECUTION_V2_1/);
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
  assert.match(reconcileV21, /revoke all on function public\.contentflow_evidence_first_reconcile/);
  assert.match(reconcileV21, /grant execute on function public\.contentflow_evidence_first_reconcile[\s\S]*service_role/);
});
