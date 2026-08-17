export type CompletionEvidence = {
  taskKey: string;
  action: 'deploy' | 'complete';
  logs: readonly string[];
  metrics: Record<string, number>;
  stateSnapshot: Record<string, unknown>;
  occurredAt: string;
};

export type PersistedEvidence = {
  evidenceId: string;
  immutableRef: string;
};

export interface DurableEvidenceStore {
  persist(evidence: CompletionEvidence): Promise<PersistedEvidence>;
}

export type CompletionDecision =
  | { ok: true; evidence: PersistedEvidence }
  | { ok: false; code: 'EVIDENCE_MISSING' | 'EVIDENCE_PERSIST_FAILED'; reason: string };

function hasEvidence(evidence: CompletionEvidence): boolean {
  return (
    evidence.taskKey.trim().length > 0 &&
    evidence.occurredAt.trim().length > 0 &&
    (evidence.logs.length > 0 ||
      Object.keys(evidence.metrics).length > 0 ||
      Object.keys(evidence.stateSnapshot).length > 0)
  );
}

/**
 * Canonical completion boundary. A deploy/completion transition is allowed
 * only after its evidence has been durably persisted and the store returns
 * stable immutable identifiers. Persistence failures are fail-closed.
 */
export async function requirePersistedCompletionEvidence(
  evidence: CompletionEvidence,
  store: DurableEvidenceStore,
): Promise<CompletionDecision> {
  if (!hasEvidence(evidence)) {
    return {
      ok: false,
      code: 'EVIDENCE_MISSING',
      reason: 'Completion requires logs, metrics, or a state snapshot.',
    };
  }

  try {
    const persisted = await store.persist(evidence);
    if (!persisted.evidenceId?.trim() || !persisted.immutableRef?.trim()) {
      return {
        ok: false,
        code: 'EVIDENCE_PERSIST_FAILED',
        reason: 'Durable evidence store did not return immutable identifiers.',
      };
    }

    return { ok: true, evidence: persisted };
  } catch (error) {
    return {
      ok: false,
      code: 'EVIDENCE_PERSIST_FAILED',
      reason: error instanceof Error ? error.message : 'Evidence persistence failed.',
    };
  }
}

export async function assertPersistedCompletionEvidence(
  evidence: CompletionEvidence,
  store: DurableEvidenceStore,
): Promise<PersistedEvidence> {
  const result = await requirePersistedCompletionEvidence(evidence, store);
  if (!result.ok) {
    throw new Error(`${result.code}:${result.reason}`);
  }
  return result.evidence;
}
