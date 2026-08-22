import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import { evaluateAutonomyAdmission } from '../supabase/functions/_shared/autonomy-admission.mjs';
import { validateRecoveryReceipt } from '../supabase/functions/_shared/recovery-certification-receipt.mjs';

const now = Date.parse('2026-08-21T20:00:00Z');
const receipt = {
  version:'recovery-certification-v1',
  project_key:'contentflow',
  certified:true,
  verified_at:'2026-08-21T19:00:00Z',
  healthy_since:'2026-08-21T19:30:00Z',
  runtime_version:'director-v9',
  snapshot:{status:'PASS',sha256:'a'.repeat(64),artifact:'contentflow-recovery-123'},
  restore:{status:'PASS',parity:'9/9',verified_at:'2026-08-21T18:00:00Z'}
};
const base = {
  nowMs: now,
  telemetryHealthy: true,
  recoveryReceipt: receipt,
  ownershipConflicts: 0,
  openIncidents: 0,
  openCircuits: 0,
  retryStates: 8,
  waitingForEvidence: 0,
  requestedParallelism: 4,
  stableParallelism: 2,
  minimumDwellMs: 5*60*1000
};

test('valid canonical recovery receipt is accepted', () => {
  const v=validateRecoveryReceipt(receipt,{nowMs:now});
  assert.equal(v.valid,true);
  assert.deepEqual(v.errors,[]);
});

test('caps productive work at certified stable parallelism after dwell', () => {
  const d = evaluateAutonomyAdmission(base);
  assert.equal(d.admitted, true);
  assert.equal(d.mode, 'productive');
  assert.equal(d.effectiveParallelism, 2);
  assert.equal(d.signals.dwellSatisfied,true);
});

test('blocks productive work when canonical recovery receipt is invalid', () => {
  const d = evaluateAutonomyAdmission({ ...base, recoveryReceipt: {} });
  assert.equal(d.admitted, false);
  assert.equal(d.mode, 'support_only');
  assert.equal(d.effectiveParallelism, 0);
  assert.ok(d.blockers.includes('recovery_receipt_invalid'));
});

test('holds support-only during stability dwell after fresh recovery', () => {
  const fresh={...receipt,healthy_since:'2026-08-21T19:58:00Z'};
  const d=evaluateAutonomyAdmission({...base,recoveryReceipt:fresh});
  assert.equal(d.admitted,false);
  assert.ok(d.blockers.includes('stability_dwell_pending'));
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

test('auto-loop uses receipt as source of truth and gates planner/core behind admission', () => {
  const s = fs.readFileSync('supabase/functions/contentflow-auto-loop/index.ts', 'utf8');
  assert.ok(s.includes(".select('status,verified,updated_at,evidence')"));
  assert.ok(s.includes('recoveryReceipt:recovery.data?.evidence||{}'));
  assert.ok(s.includes("evaluateAutonomyAdmission(signals)"));
  assert.ok(s.includes("if(admission.admitted)"));
  assert.ok(s.includes("reason:'autonomy_admission_denied'"));
  assert.ok(s.includes("reason:'recovery_aware_support_only'"));
  assert.ok(s.includes(".eq('evidence_type','recovery_certification')"));
  assert.ok(s.includes("contentflow_director_core_cycle_auto"));
});
