import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

const port = 44317;

test('Jarvis Desktop boots locally, exposes setup state, and fails closed before Director login', async (t) => {
  const child = spawn(process.execPath, ['src/jarvis/server.mjs'], {
    env: {
      ...process.env,
      JARVIS_PORT: String(port),
      JARVIS_HOST: '127.0.0.1',
      OPENAI_API_KEY: '',
      DIRECTOR_BASE_URL: '',
      DIRECTOR_TOKEN: '',
      SUPABASE_ACCESS_TOKEN: '',
      DIRECTOR_PROJECT_KEY: 'contentflow'
    },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  t.after(() => child.kill('SIGTERM'));

  let response;
  for (let i = 0; i < 30; i += 1) {
    try { response = await fetch(`http://127.0.0.1:${port}/health`); break; }
    catch { await new Promise((resolve) => setTimeout(resolve, 100)); }
  }

  assert.ok(response, 'server did not start');
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.service, 'jarvis-desktop');
  assert.equal(body.openaiConfigured, false);
  assert.equal(body.directorConfigured, false);
  assert.equal(body.directorMode, 'login-required');
  assert.equal(body.supabaseLoginRequired, true);
  assert.equal(body.projectKey, 'contentflow');

  const setup = await fetch(`http://127.0.0.1:${port}/api/setup`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ openaiApiKey: 'sk-test-memory-only' })
  });
  assert.equal(setup.status, 200);
  const setupBody = await setup.json();
  assert.equal(setupBody.health.openaiConfigured, true);
  assert.equal(setupBody.health.directorConfigured, false);

  const status = await fetch(`http://127.0.0.1:${port}/api/director/status`);
  assert.equal(status.status, 500);
  const statusBody = await status.json();
  assert.equal(statusBody.error, 'SUPABASE_login_required');
});
