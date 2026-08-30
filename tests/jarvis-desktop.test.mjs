import test from 'node:test';
import assert from 'node:assert/strict';
import { spawn } from 'node:child_process';

const port = 44317;

test('Jarvis Desktop boots locally and exposes safe health state', async (t) => {
  const child = spawn(process.execPath, ['src/jarvis/server.mjs'], {
    env: { ...process.env, JARVIS_PORT: String(port), JARVIS_HOST: '127.0.0.1', OPENAI_API_KEY: '', DIRECTOR_BASE_URL: '' },
    stdio: ['ignore', 'pipe', 'pipe']
  });
  t.after(() => child.kill('SIGTERM'));

  let response;
  for (let i = 0; i < 30; i += 1) {
    try {
      response = await fetch(`http://127.0.0.1:${port}/health`);
      break;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 100));
    }
  }

  assert.ok(response, 'server did not start');
  assert.equal(response.status, 200);
  const body = await response.json();
  assert.equal(body.ok, true);
  assert.equal(body.service, 'jarvis-desktop');
  assert.equal(body.openaiConfigured, false);
  assert.equal(body.directorConfigured, false);
});