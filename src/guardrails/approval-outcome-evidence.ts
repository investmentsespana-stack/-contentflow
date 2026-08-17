export type ApprovalOutcome = 'missing' | 'invalid' | 'valid';

export type ApprovalEvidenceEntry = {
  changeId: string;
  outcome: ApprovalOutcome;
  reason: string;
  recordedAt: string;
};

export type ApprovalEvidenceRecorder = (
  entry: ApprovalEvidenceEntry,
) => void | Promise<void>;

function nonEmpty(value: unknown): value is string {
  return typeof value === 'string' && value.trim().length > 0;
}

export async function recordApprovalOutcomeEvidence(
  input: {
    changeId: string;
    outcome: ApprovalOutcome;
    reason: string;
  },
  recorder: ApprovalEvidenceRecorder,
  now: Date = new Date(),
): Promise<ApprovalEvidenceEntry> {
  if (!nonEmpty(input.changeId)) {
    throw new Error('APPROVAL_EVIDENCE_INVALID_CHANGE_ID');
  }
  if (!['missing', 'invalid', 'valid'].includes(input.outcome)) {
    throw new Error('APPROVAL_EVIDENCE_INVALID_OUTCOME');
  }
  if (!nonEmpty(input.reason)) {
    throw new Error('APPROVAL_EVIDENCE_MISSING_REASON');
  }

  const entry: ApprovalEvidenceEntry = {
    changeId: input.changeId.trim(),
    outcome: input.outcome,
    reason: input.reason.trim(),
    recordedAt: now.toISOString(),
  };

  await recorder(entry);
  return entry;
}

export async function classifyAndRecordApprovalOutcome(
  input: {
    changeId: string;
    approvalPresent: boolean;
    cryptographicallyValid: boolean;
  },
  recorder: ApprovalEvidenceRecorder,
  now: Date = new Date(),
): Promise<ApprovalEvidenceEntry> {
  if (!input.approvalPresent) {
    return recordApprovalOutcomeEvidence(
      {
        changeId: input.changeId,
        outcome: 'missing',
        reason: 'approval_missing',
      },
      recorder,
      now,
    );
  }

  if (!input.cryptographicallyValid) {
    return recordApprovalOutcomeEvidence(
      {
        changeId: input.changeId,
        outcome: 'invalid',
        reason: 'approval_cryptographically_invalid',
      },
      recorder,
      now,
    );
  }

  return recordApprovalOutcomeEvidence(
    {
      changeId: input.changeId,
      outcome: 'valid',
      reason: 'approval_valid',
    },
    recorder,
    now,
  );
}
