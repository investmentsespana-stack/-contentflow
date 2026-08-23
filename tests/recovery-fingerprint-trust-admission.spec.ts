import { test, expect } from '@playwright/test';
import fs from 'node:fs';
import path from 'node:path';

const root = process.cwd();
const readJson = (p: string) => JSON.parse(fs.readFileSync(path.join(root, p), 'utf8'));

test('recovery fingerprint contract is deterministic and fail-closed', async () => {
  const c = readJson('docs/architecture/autonomy/recovery-fingerprint-contract.v1.json');
  expect(c.mode).toBe('fail-closed');
  expect(c.algorithm).toBe('sha256');
  expect(c.reuse_policy.exact_fingerprint_required).toBe(true);
  expect(c.reuse_policy.semantic_fallback_allowed).toBe(false);
  expect(c.reuse_policy.requires_correlated_evidence).toBe(true);
  expect(c.reuse_policy.requires_post_repair_validation).toBe(true);
  expect(c.mismatch_action).toBe('deny_reuse_and_escalate');
  expect(c.normalization.ignore_fields).toContain('free_text_message');
});

test('trust admission gate cannot bypass authority, evidence or rollback', async () => {
  const g = readJson('docs/architecture/autonomy/trust-chain-admission-gate.v1.json');
  expect(g.mode).toBe('fail-closed');
  expect(g.decision).toBe('deny_unless_all_required_checks_pass');
  for (const check of [
    'capability_registered',
    'authority_allowed',
    'incident_fingerprint_valid',
    'correlated_evidence_available',
    'rollback_available',
    'idempotency_guard_present',
    'fencing_guard_present',
    'post_repair_validator_available'
  ]) expect(g.checks).toContain(check);
  expect(g.critical_or_external_effects.owner_approval_required).toBe(true);
  expect(g.critical_or_external_effects.automatic_admission).toBe(false);
  expect(g.unknown_capability).toBe('deny_and_escalate');
  expect(g.missing_evidence).toBe('deny_and_escalate');
  expect(g.missing_rollback).toBe('deny_and_escalate');
});
