import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evaluateAutonomyAdmission } from '../supabase/functions/_shared/autonomy-admission.mjs';

const now = Date.parse('2026-08-21T20:00:00Z');
const base = {
  nowMs: now,
  telemetryHealthy: true,
  recovery: { verified: true, status: 'PASS', verifiedAt: '2026-08-21T19:00:00Z' },
  ownershipConflicts: 0,
  openIncidents: 0,
  openCircuits: 0,
  retryStates: 8,
  waitingForEvidence: 0,
  requestedParallelism: 4,
  stableParallelism: 2
};

test('caps productive work at certified stable parallelism', () => {
  const d = evaluateAutonomyAdmission(base);
  assert.equal(d.admitted, true);
  assert.equal(d.mode, 'productive');
  assert.equal(d.effectiveParallelism, 2);
});

test('blocks productive work when recovery is not certified', () => {
  const d = evaluateAutonomyAdmission({ ...base, recovery: {} });
  assert.equal(d.admitted, false);
  assert.equal(d.mode, 'support_only');
  assert.equal(d.effectiveParallelism, 0);
  assert.ok(d.blockers.includes('recovery_not_certified'));
});

test('blocks productive work on unsafe operating signals', () => {
  const cases = [
    [{ ownershipConflicts: 1 }, 'ownership_conflict'],
    [{ openIncidents: 1 }, 'open_repair_incident'],
    [{ openCircuits: 3 }, 'retry_budget_unhealthy'],
    [{ waitingForEvidence: 1 }, 'evidence_producer_gap'],
    [{ telemetryHealthy: false }, 'admission_telemetry_unavailable']
  ];
  for (const [patch, expected] of cases) {
    const d = evaluateAutonomyAdmission({ ...base, ...patch });
    assert.equal(d.admitted, false);
    assert.ok(d.blockers.includes(expected));
  }
});

test('auto-loop gates planner and single writer core behind admission', () => {
  const s = fs.readFileSync('supabase/functions/contentflow-auto-loop/index.ts', 'utf8');
  assert.ok(s.includes("evaluateAutonomyAdmission(signals)"));
  assert.ok(s.includes("if(admission.admitted)"));
  assert.ok(s.includes("reason:'autonomy_admission_denied'"));
  assert.ok(s.includes("reason:'recovery_aware_support_only'"));
  assert.ok(s.includes(".eq('evidence_type','recovery_certification')"));
  assert.ok(s.includes("contentflow_director_core_cycle_auto"));
});
