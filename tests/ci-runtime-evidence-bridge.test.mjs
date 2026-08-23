import test from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const workflow = readFileSync('.github/workflows/runtime-evidence-producer.yml','utf8');
const migration = readFileSync('supabase/migrations/20260823011200_ci_runtime_evidence_bridge_v1.sql','utf8');
const recursionGuard = readFileSync('supabase/migrations/20260823013500_prevent_recursive_evidence_requirements_v1.sql','utf8');

test('workflow accepts only fixed suites and requires correlation inputs', () => {
  assert.match(workflow, /requirement_id:/);
  assert.match(workflow, /builder_run_id:/);
  assert.match(workflow, /task_key:/);
  assert.match(workflow, /type: choice/);
  assert.doesNotMatch(workflow, /test_command:\n\s+description/);
});

test('workflow records only after the certification step', () => {
  const certify = workflow.indexOf('Run fixed certification suite');
  const record = workflow.indexOf('Record correlated PASS in Runtime Evidence Ledger');
  assert.ok(certify >= 0 && record > certify);
  assert.match(workflow, /passed:true/);
});

test('database bridge is correlation strict and fail closed', () => {
  assert.match(migration, /requirement_correlation_mismatch/);
  assert.match(migration, /passing_nonempty_payload_required/);
  assert.match(migration, /producer='github-actions-ci'/);
  assert.match(migration, /requirement_id=er\.id/);
  assert.match(migration, /revoke all .* from public, anon, authenticated/i);
});

test('evidence-first reconciliation cannot create evidence-of-evidence descendants', () => {
  assert.match(recursionGuard, /b\.task_key not like ''evidence_%''/);
  assert.match(recursionGuard, /recursive_evidence_quarantined/);
  assert.match(recursionGuard, /task_key like 'evidence_evidence_%'/);
  assert.match(recursionGuard, /delete from public\.contentflow_evidence_requirements/);
});
