import { test, expect } from '@playwright/test';
import {
  classifyAndRecordApprovalOutcome,
  type ApprovalEvidenceEntry,
} from '../src/guardrails/approval-outcome-evidence';

test('records evidence for missing, invalid and valid approvals', async () => {
  const entries: ApprovalEvidenceEntry[] = [];
  const recorder = async (entry: ApprovalEvidenceEntry) => entries.push(entry);
  const now = new Date('2026-08-17T15:00:00.000Z');

  await classifyAndRecordApprovalOutcome(
    { changeId: 'chg-1', approvalPresent: false, cryptographicallyValid: false },
    recorder,
    now,
  );
  await classifyAndRecordApprovalOutcome(
    { changeId: 'chg-2', approvalPresent: true, cryptographicallyValid: false },
    recorder,
    now,
  );
  await classifyAndRecordApprovalOutcome(
    { changeId: 'chg-3', approvalPresent: true, cryptographicallyValid: true },
    recorder,
    now,
  );

  expect(entries).toEqual([
    {
      changeId: 'chg-1',
      outcome: 'missing',
      reason: 'approval_missing',
      recordedAt: now.toISOString(),
    },
    {
      changeId: 'chg-2',
      outcome: 'invalid',
      reason: 'approval_cryptographically_invalid',
      recordedAt: now.toISOString(),
    },
    {
      changeId: 'chg-3',
      outcome: 'valid',
      reason: 'approval_valid',
      recordedAt: now.toISOString(),
    },
  ]);
});

test('does not claim evidence was recorded when persistence fails', async () => {
  await expect(
    classifyAndRecordApprovalOutcome(
      { changeId: 'chg-fail', approvalPresent: true, cryptographicallyValid: true },
      async () => {
        throw new Error('durable_store_unavailable');
      },
    ),
  ).rejects.toThrow('durable_store_unavailable');
});

test('rejects evidence without change_id-equivalent correlation', async () => {
  await expect(
    classifyAndRecordApprovalOutcome(
      { changeId: '   ', approvalPresent: false, cryptographicallyValid: false },
      async () => undefined,
    ),
  ).rejects.toThrow('APPROVAL_EVIDENCE_INVALID_CHANGE_ID');
});
