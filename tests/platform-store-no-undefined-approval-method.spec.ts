import { expect, test } from '@playwright/test';
import { readdir, readFile } from 'node:fs/promises';
import { join } from 'node:path';

async function sourceFiles(root: string): Promise<string[]> {
  const entries = await readdir(root, { withFileTypes: true });
  const out: string[] = [];
  for (const entry of entries) {
    const path = join(root, entry.name);
    if (entry.isDirectory()) out.push(...await sourceFiles(path));
    else if (/\.(ts|tsx|js|jsx)$/.test(entry.name)) out.push(path);
  }
  return out;
}

test('source code never calls undefined PlatformStore get_approval_record()', async () => {
  const files = await sourceFiles('src');
  const offenders: string[] = [];
  for (const file of files) {
    const text = await readFile(file, 'utf8');
    if (/\.get_approval_record\s*\(/.test(text)) offenders.push(file);
  }
  expect(offenders, 'undefined PlatformStore method must not appear in src').toEqual([]);
});

test('canonical approval reader remains the only documented PlatformStore path', async () => {
  const text = await readFile('src/platform/platform-store.ts', 'utf8');
  expect(text).toContain("store.read<ApprovalRecord>(approvalStorageKey(changeId), 'approvals')");
  expect(text).toContain('export async function readApprovalRecord');
});
