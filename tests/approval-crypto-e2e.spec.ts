import { expect, test } from '@playwright/test';
import {
  ApprovalIngestionGate,
  canonicalApprovalMessage,
  Ed25519ApprovalCryptoValidator,
  type ApprovalCryptoRecord,
  type ApprovalValidationEvent,
} from '../src/platform/approval-crypto-validator';

function base64Url(bytes: ArrayBuffer): string {
  const raw = String.fromCharCode(...new Uint8Array(bytes));
  return btoa(raw).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/g, '');
}

async function fixture() {
  const pair = (await crypto.subtle.generateKey(
    { name: 'Ed25519' },
    true,
    ['sign', 'verify'],
  )) as CryptoKeyPair;
  const events: ApprovalValidationEvent[] = [];
  const validator = new Ed25519ApprovalCryptoValidator(
    {
      async resolvePublicKey(keyId) {
        return keyId === 'platform-key-1' ? pair.publicKey : null;
      },
    },
    { record(event) { events.push(event); } },
  );
  const unsigned: ApprovalCryptoRecord = {
    approvalId: 'approval-42',
    changeId: 'change-42',
    payloadHash: 'sha256:6d0f-example-digest',
    signature: '',
    signerKeyId: 'platform-key-1',
    algorithm: 'ed25519+sha256',
  };
  const signature = await crypto.subtle.sign(
    { name: 'Ed25519' },
    pair.privateKey,
    canonicalApprovalMessage(unsigned),
  );
  const record = { ...unsigned, signature: base64Url(signature) };
  return { pair, events, validator, record };
}

test('approval ingestion accepts a valid real Ed25519 signature and emits success evidence', async () => {
  const { events, validator, record } = await fixture();
  const gate = new ApprovalIngestionGate(validator);
  await expect(gate.ingest(record, {
    changeId: record.changeId,
    expectedPayloadHash: record.payloadHash,
  })).resolves.toEqual({ accepted: true, reason: 'valid' });
  expect(events.at(-1)).toMatchObject({
    event: 'approval_validation_succeeded',
    approvalId: 'approval-42',
    reason: 'valid',
  });
});

test('tampered approval is rejected before ingestion and logs the exact failure reason', async () => {
  const { events, validator, record } = await fixture();
  const gate = new ApprovalIngestionGate(validator);
  const tampered = { ...record, payloadHash: 'sha256:tampered' };
  await expect(gate.ingest(tampered, {
    changeId: record.changeId,
    expectedPayloadHash: record.payloadHash,
  })).resolves.toEqual({ accepted: false, reason: 'payload_hash_mismatch' });
  expect(events.at(-1)).toMatchObject({
    event: 'approval_validation_failed',
    reason: 'payload_hash_mismatch',
  });
});

test('invalid signature and unavailable platform key both fail closed', async () => {
  const { validator, record } = await fixture();
  const context = { changeId: record.changeId, expectedPayloadHash: record.payloadHash };
  await expect(validator.validate({ ...record, signature: 'AA' }, context))
    .resolves.toEqual({ valid: false, reason: 'invalid_signature' });
  await expect(validator.validate({ ...record, signerKeyId: 'missing-key' }, context))
    .resolves.toEqual({ valid: false, reason: 'verification_material_unavailable' });
});

test('ingestion wrapper adds no material throughput regression over cryptographic validation', async () => {
  const { validator, record } = await fixture();
  const context = { changeId: record.changeId, expectedPayloadHash: record.payloadHash };
  const gate = new ApprovalIngestionGate(validator);
  const iterations = 40;

  const directStart = performance.now();
  for (let i = 0; i < iterations; i += 1) {
    expect((await validator.validate(record, context)).valid).toBe(true);
  }
  const directMs = performance.now() - directStart;

  const gateStart = performance.now();
  for (let i = 0; i < iterations; i += 1) {
    expect((await gate.ingest(record, context)).accepted).toBe(true);
  }
  const gateMs = performance.now() - gateStart;

  // Gate overhead is only the integration wrapper. Generous jitter allowance keeps
  // this a regression detector rather than a machine-speed benchmark.
  expect(gateMs).toBeLessThanOrEqual(directMs * 2 + 100);
});
