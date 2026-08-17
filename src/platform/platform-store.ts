export type StoreScope = 'approvals' | 'evidence' | 'claims';

export type ApprovalRecord = {
  id: string;
  changeId: string;
  status: 'pending' | 'approved' | 'rejected';
  approverId: string;
  approvedAt: string | null;
  signature?: string;
  claimId?: string;
};

export interface PlatformStore {
  read<T>(key: string, scope: StoreScope): Promise<T | null>;
  recordEvidence(builderRunId: string, event: Record<string, unknown>): Promise<void>;
}

export function approvalStorageKey(changeId: string): string {
  return `approval:${changeId}`;
}

export async function readApprovalRecord(
  store: PlatformStore,
  changeId: string,
): Promise<ApprovalRecord | null> {
  return store.read<ApprovalRecord>(approvalStorageKey(changeId), 'approvals');
}
