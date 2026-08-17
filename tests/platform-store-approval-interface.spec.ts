import { expect, test } from '@playwright/test';
import {
  approvalStorageKey,
  readApprovalRecord,
  type ApprovalRecord,
  type PlatformStore,
  type StoreScope,
} from '../src/platform/platform-store';

class MemoryStore implements PlatformStore {
  reads: Array<{ key: string; scope: StoreScope }> = [];
  private records = new Map<string, unknown>();

  put<T>(key: string, scope: StoreScope, value: T): void {
    this.records.set(`${scope}:${key}`, value);
  }

  async read<T>(key: string, scope: StoreScope): Promise<T | null> {
    this.reads.push({ key, scope });
    return (this.records.get(`${scope}:${key}`) as T | undefined) ?? null;
  }

  async recordEvidence(): Promise<void> {}
}

test('uses canonical approvals scope and approval key', async () => {
  const store = new MemoryStore();
  const record: ApprovalRecord = {
    id: 'a1',
    changeId: 'change-42',
    status: 'approved',
    approverId: 'reviewer-1',
    approvedAt: '2026-08-17T21:00:00Z',
  };
  store.put(approvalStorageKey('change-42'), 'approvals', record);

  await expect(readApprovalRecord(store, 'change-42')).resolves.toEqual(record);
  expect(store.reads).toEqual([{ key: 'approval:change-42', scope: 'approvals' }]);
});

test('returns null when the approval record does not exist', async () => {
  const store = new MemoryStore();
  await expect(readApprovalRecord(store, 'missing')).resolves.toBeNull();
  expect(store.reads).toEqual([{ key: 'approval:missing', scope: 'approvals' }]);
});
