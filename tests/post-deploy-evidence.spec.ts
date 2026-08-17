import { expect, test } from '@playwright/test';
import {
  assertPersistedCompletionEvidence,
  requirePersistedCompletionEvidence,
  type DurableEvidenceStore,
} from '../src/guardrails/post-deploy-evidence';

const validEvidence = {
  taskKey: 'deploy-42',
  action: 'deploy' as const,
  logs: ['deployment started', 'deployment healthy'],
  metrics: { successRate: 1 },
  stateSnapshot: { version: 'v42', healthy: true },
  occurredAt: '2026-08-17T09:55:00Z',
};

test('rejects completion when no evidence artifacts are present', async () => {
  const store: DurableEvidenceStore = {
    persist: async () => ({ evidenceId: 'never', immutableRef: 'never' }),
  };

  const result = await requirePersistedCompletionEvidence(
    { ...validEvidence, logs: [], metrics: {}, stateSnapshot: {} },
    store,
  );

  expect(result).toEqual({
    ok: false,
    code: 'EVIDENCE_MISSING',
    reason: 'Completion requires logs, metrics, or a state snapshot.',
  });
});

test('fails closed when durable persistence throws', async () => {
  const store: DurableEvidenceStore = {
    persist: async () => {
      throw new Error('durable-store-unavailable');
    },
  };

  await expect(assertPersistedCompletionEvidence(validEvidence, store)).rejects.toThrow(
    'EVIDENCE_PERSIST_FAILED:durable-store-unavailable',
  );
});

test('rejects persistence responses without immutable identifiers', async () => {
  const store: DurableEvidenceStore = {
    persist: async () => ({ evidenceId: '', immutableRef: '' }),
  };

  expect(await requirePersistedCompletionEvidence(validEvidence, store)).toEqual({
    ok: false,
    code: 'EVIDENCE_PERSIST_FAILED',
    reason: 'Durable evidence store did not return immutable identifiers.',
  });
});

test('allows completion only after durable evidence is persisted', async () => {
  let persisted = false;
  const store: DurableEvidenceStore = {
    persist: async (evidence) => {
      persisted = evidence.taskKey === validEvidence.taskKey;
      return {
        evidenceId: 'evidence-42',
        immutableRef: 'sha256:abc123',
      };
    },
  };

  const result = await requirePersistedCompletionEvidence(validEvidence, store);
  expect(persisted).toBe(true);
  expect(result).toEqual({
    ok: true,
    evidence: {
      evidenceId: 'evidence-42',
      immutableRef: 'sha256:abc123',
    },
  });
});
