import test from 'node:test';
import assert from 'node:assert/strict';
import { mkdtemp, mkdir, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { scanDeploymentArtifacts } from '../scripts/full-deployment-secret-scan.mjs';

async function fixture(files) {
  const root = await mkdtemp(join(tmpdir(), 'contentflow-secret-scan-'));
  for (const [path, content] of Object.entries(files)) {
    const full = join(root, path);
    await mkdir(full.slice(0, full.lastIndexOf('/')), { recursive: true }).catch(() => {});
    await writeFile(full, content, 'utf8');
  }
  return root;
}

function syntheticJwt(role) {
  const enc = (value) => Buffer.from(JSON.stringify(value)).toString('base64url');
  return `${enc({ alg: 'HS256', typ: 'JWT' })}.${enc({ role, ref: 'fixture' })}.${'a'.repeat(32)}`;
}

test('passes clean deployment artifacts and reports all scanned files', async () => {
  const root = await fixture({
    'supabase/migrations/001.sql': 'create table public.a(id bigint);',
    '.github/workflows/ci.yml': 'name: ci\n',
    'vercel.json': '{"version":2}',
  });
  const report = await scanDeploymentArtifacts(root);
  assert.equal(report.passed, true);
  assert.equal(report.secretValuesExposed, false);
  assert.equal(report.scannedFileCount, 3);
  assert.deepEqual(report.findings, []);
});

test('fails closed on a secret but never emits the secret value', async () => {
  const secret = 'ghp_123456789012345678901234567890123456';
  const root = await fixture({
    'supabase/functions/a/index.ts': `const token = '${secret}';`,
  });
  const report = await scanDeploymentArtifacts(root);
  assert.equal(report.passed, false);
  assert.equal(report.secretValuesExposed, false);
  assert.equal(report.findings[0].pattern, 'github_token');
  assert.equal(JSON.stringify(report).includes(secret), false);
});

test('does not treat a Supabase anon JWT as a secret finding', async () => {
  const anon = syntheticJwt('anon');
  const root = await fixture({ 'backups/schema.sql': `v_anon text := '${anon}';` });
  const report = await scanDeploymentArtifacts(root);
  assert.equal(report.passed, true);
  assert.deepEqual(report.findings, []);
});

test('still fails closed on non-anon JWT roles without exposing the token', async () => {
  const serviceRole = syntheticJwt('service_role');
  const root = await fixture({ 'supabase/functions/a/index.ts': `const value = '${serviceRole}';` });
  const report = await scanDeploymentArtifacts(root);
  assert.equal(report.passed, false);
  assert.equal(report.findings.some((entry) => entry.pattern === 'jwt'), true);
  assert.equal(JSON.stringify(report).includes(serviceRole), false);
});
