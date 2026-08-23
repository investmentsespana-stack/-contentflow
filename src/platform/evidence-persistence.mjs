import { createHash } from 'node:crypto';

export class EvidencePersistenceError extends Error {
  constructor(message, options = {}) {
    super(message, options);
    this.name = 'EvidencePersistenceError';
  }
}

function canonicalJson(value) {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonicalJson).join(',')}]`;
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${canonicalJson(value[key])}`).join(',')}}`;
}

export function evidenceDigest(payload) {
  return createHash('sha256').update(canonicalJson(payload), 'utf8').digest('hex');
}

export function evidenceStorageKey({ projectKey, builderRunId, evidenceKey, payload }) {
  if (!projectKey || !builderRunId || !evidenceKey) {
    throw new EvidencePersistenceError('projectKey, builderRunId and evidenceKey are required');
  }
  const sha256 = evidenceDigest(payload);
  return `${projectKey}/${builderRunId}/${encodeURIComponent(evidenceKey)}/${sha256}.json`;
}

export function createEvidencePersistence({ putIfAbsent, uriForKey }) {
  if (typeof putIfAbsent !== 'function' || typeof uriForKey !== 'function') {
    throw new EvidencePersistenceError('putIfAbsent and uriForKey adapters are required');
  }

  return async function persistEvidence(input) {
    if (!input || input.payload == null || (typeof input.payload === 'object' && Object.keys(input.payload).length === 0)) {
      throw new EvidencePersistenceError('non-empty evidence payload is required');
    }

    const key = evidenceStorageKey(input);
    const body = canonicalJson({
      project_key: input.projectKey,
      builder_run_id: input.builderRunId,
      evidence_key: input.evidenceKey,
      evidence_type: input.evidenceType ?? 'runtime',
      observed_at: input.observedAt ?? new Date().toISOString(),
      payload: input.payload,
      payload_sha256: evidenceDigest(input.payload),
    });

    try {
      await putIfAbsent(key, body);
    } catch (cause) {
      throw new EvidencePersistenceError('durable evidence write failed', { cause });
    }

    const uri = await uriForKey(key);
    if (typeof uri !== 'string' || !/^(evidence|https|s3):\/\//.test(uri)) {
      throw new EvidencePersistenceError('storage adapter returned an unverifiable URI');
    }

    return Object.freeze({
      key,
      uri,
      sha256: evidenceDigest(input.payload),
    });
  };
}
