import { chromium } from '@playwright/test';
import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';

const DEFAULT_TIMEOUT_MS = 45_000;

function assertHttpUrl(value) {
  const url = new URL(value);
  if (!['http:', 'https:'].includes(url.protocol)) throw new Error('browser_worker_invalid_protocol');
  return url;
}

function normalizeTask(task = {}) {
  if (!task.id) task.id = crypto.randomUUID();
  if (!task.url) throw new Error('browser_worker_url_required');
  assertHttpUrl(task.url);
  return {
    id: task.id,
    url: task.url,
    operation: task.operation ?? 'inspect',
    selector: task.selector ?? 'body',
    screenshot: task.screenshot !== false,
    storageStatePath: task.storageStatePath ?? null,
    persistStorageState: task.persistStorageState === true,
    timeoutMs: Math.min(Number(task.timeoutMs ?? DEFAULT_TIMEOUT_MS), 120_000),
    evidenceDir: task.evidenceDir ?? 'certification-evidence/browser-worker',
  };
}

export async function runBrowserTask(input, deps = {}) {
  const task = normalizeTask({ ...input });
  const startedAt = new Date().toISOString();
  const evidenceDir = path.resolve(task.evidenceDir, task.id);
  await fs.mkdir(evidenceDir, { recursive: true });

  const browserFactory = deps.browserFactory ?? (() => chromium.launch({ headless: true }));
  const browser = await browserFactory();
  let context;
  try {
    context = await browser.newContext(task.storageStatePath ? { storageState: task.storageStatePath } : {});
    const page = await context.newPage();
    page.setDefaultTimeout(task.timeoutMs);
    const response = await page.goto(task.url, { waitUntil: 'domcontentloaded', timeout: task.timeoutMs });
    const title = await page.title();
    const finalUrl = page.url();
    const text = await page.locator(task.selector).innerText({ timeout: task.timeoutMs });
    const bodyExcerpt = text.slice(0, 4000);

    let screenshotPath = null;
    if (task.screenshot) {
      screenshotPath = path.join(evidenceDir, 'page.png');
      await page.screenshot({ path: screenshotPath, fullPage: true });
    }

    let storageStatePath = null;
    if (task.persistStorageState) {
      storageStatePath = path.join(evidenceDir, 'storage-state.json');
      await context.storageState({ path: storageStatePath });
    }

    const receipt = {
      schema: 'nexo.browser.receipt.v1',
      taskId: task.id,
      status: 'completed',
      operation: task.operation,
      requestedUrl: task.url,
      finalUrl,
      httpStatus: response?.status() ?? null,
      title,
      bodyExcerpt,
      screenshotPath,
      storageStatePath,
      startedAt,
      completedAt: new Date().toISOString(),
      worker: 'browser-worker',
      backend: 'playwright',
    };
    const receiptPath = path.join(evidenceDir, 'receipt.json');
    await fs.writeFile(receiptPath, JSON.stringify(receipt, null, 2));
    return { ...receipt, receiptPath };
  } catch (error) {
    const failed = {
      schema: 'nexo.browser.receipt.v1',
      taskId: task.id,
      status: 'failed',
      requestedUrl: task.url,
      startedAt,
      completedAt: new Date().toISOString(),
      worker: 'browser-worker',
      backend: 'playwright',
      error: error instanceof Error ? error.message : String(error),
    };
    await fs.writeFile(path.join(evidenceDir, 'receipt.json'), JSON.stringify(failed, null, 2));
    throw error;
  } finally {
    await context?.close().catch(() => {});
    await browser.close().catch(() => {});
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const url = process.argv[2] ?? process.env.BROWSER_WORKER_URL ?? 'https://example.com';
  const result = await runBrowserTask({
    id: process.env.BROWSER_WORKER_TASK_ID ?? `smoke-${Date.now()}`,
    url,
    operation: 'inspect',
    persistStorageState: process.env.BROWSER_WORKER_PERSIST_STATE === '1',
  });
  process.stdout.write(`${JSON.stringify(result, null, 2)}\n`);
}
