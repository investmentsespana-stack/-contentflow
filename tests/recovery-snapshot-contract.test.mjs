import assert from 'node:assert/strict';
import { createHash } from 'node:crypto';
import { mkdtempSync, writeFileSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import test from 'node:test';
import { verifyRecoverySnapshot } from '../.github/scripts/verify-recovery-snapshot.mjs';

function fixture(createdAt = '2026-08-23T12:00:00Z') {
  const dir = mkdtempSync(join(tmpdir(), 'cf-recovery-'));
  const files = {
    'schema.sql': 'CREATE TABLE test(id bigint);\n',
    'public-schema.sql': 'CREATE TABLE public.test(id bigint);\n',
    'runtime-control-data.sql': 'INSERT INTO director_control_policy VALUES (1);\n',
  };
  for (const [name, body] of Object.entries(files)) writeFileSync(join(dir, name), body);
  writeFileSync(join(dir, 'manifest.json'), JSON.stringify({
    project_ref: 'koqpyfvnprmirqviafzq',
    created_at_utc: createdAt,
    restore_order: ['public-schema.sql','runtime-control-data.sql'],
    integrity: 'SHA256SUMS',
  }));
  writeFileSync(join(dir, 'SHA256SUMS'), Object.entries(files).map(([name, body]) => `${createHash('sha256').update(body).digest('hex')}  ${name}`).join('\n') + '\n');
  return dir;
}

test('fresh complete snapshot is rollback-viable', () => {
  const dir = fixture();
  try {
    const result = verifyRecoverySnapshot({ dir, projectRef: 'koqpyfvnprmirqviafzq', deploymentStart: new Date('2026-08-23T12:30:00Z'), maxAgeMinutes: 60 });
    assert.equal(result.passed, true);
    assert.equal(result.rollbackPlanViable, true);
    assert.equal(result.pathChecks.every((x) => x.exists), true);
    assert.equal(result.checksumChecks.every((x) => x.matches), true);
    assert.equal(result.ageMinutes, 30);
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('missing path fails closed', () => {
  const dir = fixture();
  try {
    rmSync(join(dir, 'runtime-control-data.sql'));
    assert.equal(verifyRecoverySnapshot({ dir, projectRef: 'koqpyfvnprmirqviafzq' }).reason, 'required_backup_path_missing');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('checksum mismatch fails closed', () => {
  const dir = fixture();
  try {
    writeFileSync(join(dir, 'schema.sql'), 'tampered');
    assert.equal(verifyRecoverySnapshot({ dir, projectRef: 'koqpyfvnprmirqviafzq', deploymentStart: new Date('2026-08-23T12:30:00Z') }).reason, 'backup_checksum_mismatch');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});

test('snapshot older than one hour fails closed', () => {
  const dir = fixture('2026-08-23T10:00:00Z');
  try {
    const result = verifyRecoverySnapshot({ dir, projectRef: 'koqpyfvnprmirqviafzq', deploymentStart: new Date('2026-08-23T12:00:01Z'), maxAgeMinutes: 60 });
    assert.equal(result.passed, false);
    assert.equal(result.reason, 'backup_outside_freshness_window');
  } finally { rmSync(dir, { recursive: true, force: true }); }
});
