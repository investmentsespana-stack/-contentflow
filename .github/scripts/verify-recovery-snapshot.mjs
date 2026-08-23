import { createHash } from 'node:crypto';
import { existsSync, readFileSync } from 'node:fs';
import { basename, join } from 'node:path';

export function verifyRecoverySnapshot({
  dir,
  projectRef,
  deploymentStart = new Date(),
  maxAgeMinutes = 60,
}) {
  const manifestPath = join(dir, 'manifest.json');
  const sumsPath = join(dir, 'SHA256SUMS');
  const requiredControlFiles = ['schema.sql', 'public-schema.sql', 'runtime-control-data.sql'];
  const checksumFiles = [...requiredControlFiles, 'manifest.json'];
  const requiredPaths = [manifestPath, sumsPath, ...requiredControlFiles.map((f) => join(dir, f))];

  const pathChecks = requiredPaths.map((path) => ({ path, exists: existsSync(path) }));
  if (pathChecks.some((x) => !x.exists)) {
    return { passed: false, reason: 'required_backup_path_missing', pathChecks };
  }

  const manifest = JSON.parse(readFileSync(manifestPath, 'utf8'));
  if (manifest.project_ref !== projectRef) {
    return { passed: false, reason: 'project_ref_mismatch', pathChecks };
  }
  if (manifest.integrity !== 'SHA256SUMS') {
    return { passed: false, reason: 'integrity_contract_missing', pathChecks };
  }
  const expectedRestoreOrder = ['public-schema.sql', 'runtime-control-data.sql', 'supabase/migrations after repo_migration_cutoff'];
  if (JSON.stringify(manifest.restore_order) !== JSON.stringify(expectedRestoreOrder)) {
    return { passed: false, reason: 'restore_order_invalid', pathChecks };
  }
  if (manifest.migration_replay_contract !== 'REPLAY_SUPABASE_MIGRATIONS_AFTER_CUTOFF_V1') {
    return { passed: false, reason: 'migration_replay_contract_missing', pathChecks };
  }
  if (typeof manifest.repo_migration_cutoff !== 'string' || !/^\d{14}_.+\.sql$/.test(manifest.repo_migration_cutoff)) {
    return { passed: false, reason: 'repo_migration_cutoff_invalid', pathChecks };
  }
  if (typeof manifest.database_migration_head !== 'string' || !/^\d{14}$/.test(manifest.database_migration_head)) {
    return { passed: false, reason: 'database_migration_head_invalid', pathChecks };
  }

  const sumLines = readFileSync(sumsPath, 'utf8').trim().split(/\r?\n/).filter(Boolean);
  const expected = new Map(sumLines.map((line) => {
    const match = line.match(/^([a-f0-9]{64})\s+\*?(.+)$/i);
    if (!match) throw new Error(`invalid SHA256SUMS line: ${line}`);
    return [basename(match[2]), match[1].toLowerCase()];
  }));

  const checksumChecks = checksumFiles.map((file) => {
    const path = join(dir, file);
    const actual = createHash('sha256').update(readFileSync(path)).digest('hex');
    return { file, expected: expected.get(file) ?? null, actual, matches: expected.get(file) === actual };
  });
  if (checksumChecks.some((x) => !x.matches)) {
    return { passed: false, reason: 'backup_checksum_mismatch', pathChecks, checksumChecks };
  }

  const createdAt = new Date(manifest.created_at_utc);
  if (!Number.isFinite(createdAt.getTime())) {
    return { passed: false, reason: 'backup_timestamp_invalid', pathChecks, checksumChecks };
  }
  const ageMs = deploymentStart.getTime() - createdAt.getTime();
  const ageMinutes = ageMs / 60000;
  if (ageMs < 0 || ageMinutes > maxAgeMinutes) {
    return { passed: false, reason: 'backup_outside_freshness_window', pathChecks, checksumChecks, createdAtUtc: createdAt.toISOString(), deploymentStartUtc: deploymentStart.toISOString(), ageMinutes, maxAgeMinutes };
  }

  return {
    passed: true,
    architecture: 'RECOVERY_SNAPSHOT_MIGRATION_REPLAY_CONTRACT_V2',
    projectRef,
    requiredPaths: requiredPaths.map((p) => p),
    pathChecks,
    checksumChecks: checksumChecks.map(({ file, matches }) => ({ file, matches })),
    restoreOrder: manifest.restore_order,
    repoMigrationCutoff: manifest.repo_migration_cutoff,
    databaseMigrationHead: manifest.database_migration_head,
    migrationReplayContract: manifest.migration_replay_contract,
    createdAtUtc: createdAt.toISOString(),
    deploymentStartUtc: deploymentStart.toISOString(),
    ageMinutes,
    maxAgeMinutes,
    rollbackPlanViable: true,
    deterministicReplayViable: true,
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const dir = process.argv[2];
  if (!dir) throw new Error('usage: node verify-recovery-snapshot.mjs <snapshot-dir>');
  const result = verifyRecoverySnapshot({
    dir,
    projectRef: process.env.CONTENTFLOW_PROJECT_REF ?? 'koqpyfvnprmirqviafzq',
    deploymentStart: new Date(process.env.DEPLOYMENT_START_UTC ?? Date.now()),
    maxAgeMinutes: Number(process.env.MAX_BACKUP_AGE_MINUTES ?? '60'),
  });
  process.stdout.write(JSON.stringify(result));
  if (!result.passed) process.exitCode = 1;
}
