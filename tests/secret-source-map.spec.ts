import { test, expect } from '@playwright/test';
import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';

const map = readFileSync(resolve(process.cwd(), 'docs/security/SECRET_SOURCE_MAP.md'), 'utf8');

test('secret source map covers canonical secret references', async () => {
  for (const required of [
    'SUPABASE_SERVICE_ROLE_KEY',
    'NEXOROUTER_API_KEY',
    'runner_secret',
    'SUPABASE_URL',
    'SUPABASE_ANON_KEY',
    'contentflow-auto-loop',
    'contentflow-rara',
    'contentflow-builder-agent-runner-v2',
    'contentflow-dispatch-executor-v2',
    'contentflow-app',
  ]) {
    expect(map, `missing mapping for ${required}`).toContain(required);
  }
});

test('only approved secret/config source channels are documented', async () => {
  for (const channel of ['supabase_edge_secret', 'service_role_rls_table', 'public_config']) {
    expect(map).toContain(channel);
  }
  expect(map).toContain('RLS enabled');
  expect(map).toContain('postgres');
  expect(map).toContain('service_role');
});

test('mapping never embeds representative privileged secret literals', async () => {
  expect(map).not.toMatch(/eyJhbGciOiJIUzI1NiJ9\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/);
  expect(map).not.toMatch(/sk-[A-Za-z0-9_-]{20,}/);
  expect(map).not.toMatch(/github_pat_[A-Za-z0-9_]{20,}/);
  expect(map).not.toMatch(/AKIA[0-9A-Z]{16}/);
});
