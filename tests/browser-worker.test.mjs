import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { runBrowserTask } from '../src/platform/browser-worker.mjs';

function fakeBrowser() {
  return {
    async newContext() {
      return {
        async newPage() {
          return {
            setDefaultTimeout() {},
            async goto() { return { status: () => 200 }; },
            async title() { return 'Example Domain'; },
            url() { return 'https://example.com/'; },
            locator() { return { innerText: async () => 'Example Domain\nThis domain is for use in illustrative examples.' }; },
            async screenshot({ path: out }) { await fs.writeFile(out, 'fake-png'); },
          };
        },
        async storageState({ path: out }) { await fs.writeFile(out, '{}'); },
        async close() {},
      };
    },
    async close() {},
  };
}

test('browser worker emits deterministic evidence receipt', async () => {
  const dir = await fs.mkdtemp(path.join(os.tmpdir(), 'nexo-browser-worker-'));
  const receipt = await runBrowserTask({
    id: 'browser-worker-cert',
    url: 'https://example.com',
    evidenceDir: dir,
    persistStorageState: true,
  }, { browserFactory: async () => fakeBrowser() });

  assert.equal(receipt.schema, 'nexo.browser.receipt.v1');
  assert.equal(receipt.status, 'completed');
  assert.equal(receipt.httpStatus, 200);
  assert.equal(receipt.title, 'Example Domain');
  assert.equal(receipt.worker, 'browser-worker');
  assert.equal(receipt.backend, 'playwright');
  assert.ok(receipt.screenshotPath);
  assert.ok(receipt.storageStatePath);
  const stored = JSON.parse(await fs.readFile(receipt.receiptPath, 'utf8'));
  assert.equal(stored.taskId, 'browser-worker-cert');
});

test('browser worker rejects non-http protocols', async () => {
  await assert.rejects(
    () => runBrowserTask({ id: 'bad', url: 'file:///etc/passwd' }, { browserFactory: async () => fakeBrowser() }),
    /invalid_protocol/,
  );
});
