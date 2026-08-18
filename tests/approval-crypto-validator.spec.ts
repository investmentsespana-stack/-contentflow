import { expect, test } from '@playwright/test';
import {
  FailClosedApprovalCryptoValidator,
  type ApprovalChangeContext,
  type ApprovalCryptoRecord,
  type ApprovalCryptoValidator,
} from '../src/platform/approval-crypto-validator';

test('approval crypto stub implements the canonical typed interface and fails closed', async () => {
  const validator: ApprovalCryptoValidator = new FailClosedApprovalCryptoValidator();
  const record: ApprovalCryptoRecord = {
    approvalId: 'approval-1',
    changeId: 'change-1',
    payloadHash: 'sha256:placeholder',
    signature: 'placeholder-signature',
    signerKeyId: 'key-1',
    algorithm: 'ed25519+sha256',
  };
  const context: ApprovalChangeContext = {
    changeId: 'change-1',
    expectedPayloadHash: 'sha256:placeholder',
  };

  await expect(validator.validate(record, context)).resolves.toEqual({
    valid: false,
    reason: 'not_implemented',
  });
});
