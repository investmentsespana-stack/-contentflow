import { createHash } from 'node:crypto';

export type RejectionClass = 'missing_required_field' | 'secret_or_pii' | 'unverified_assumption' | 'invalid_format';

export function classifyRejectedInput(input: { missingFields?: string[]; secretOrPii?: boolean; unverifiedAssumption?: boolean; invalidFormat?: boolean }): RejectionClass {
  if (input.secretOrPii) return 'secret_or_pii';
  if (input.missingFields?.length) return 'missing_required_field';
  if (input.unverifiedAssumption) return 'unverified_assumption';
  if (input.invalidFormat) return 'invalid_format';
  throw new Error('REJECTION_CLASS_UNRESOLVED');
}

export function captureRejectionEvidence(payload: unknown, rejectionReason: RejectionClass, at = new Date()): { input_hash: string; timestamp: string; rejection_reason: RejectionClass } {
  return {
    input_hash: createHash('sha256').update(JSON.stringify(payload)).digest('hex'),
    timestamp: at.toISOString(),
    rejection_reason: rejectionReason,
  };
}

export type CoherenceViolation = { type: 'topic_drift' | 'contradiction' | 'fragmented_logic'; message: string };
export function detectCoherenceViolations(scores: { topicContinuity: number; contradictionRisk: number; logicalContinuity: number }, threshold = 0.7): CoherenceViolation[] {
  const out: CoherenceViolation[] = [];
  if (scores.topicContinuity < threshold) out.push({ type: 'topic_drift', message: 'Topic continuity is below threshold.' });
  if (scores.contradictionRisk > 1 - threshold) out.push({ type: 'contradiction', message: 'Contradiction risk exceeds threshold.' });
  if (scores.logicalContinuity < threshold) out.push({ type: 'fragmented_logic', message: 'Logical continuity is below threshold.' });
  return out;
}

export function enforceRequiredFields<T extends Record<string, unknown>>(payload: T, requiredFields: readonly string[]): { status: 200; payload: T } | { status: 400; code: 'MISSING_REQUIRED_FIELDS'; missingFields: string[] } {
  const missingFields = requiredFields.filter((key) => payload[key] === undefined || payload[key] === null || payload[key] === '');
  return missingFields.length ? { status: 400, code: 'MISSING_REQUIRED_FIELDS', missingFields } : { status: 200, payload };
}

export function hasRequiredEvidenceFields(record: Record<string, unknown>, fields: readonly string[]): boolean {
  return fields.every((field) => record[field] !== undefined && record[field] !== null);
}

export function detectMissingEvidenceCases(records: readonly Record<string, unknown>[], fields: readonly string[]): { total: number; missing: number; valid: number } {
  let missing = 0;
  for (const record of records) if (!hasRequiredEvidenceFields(record, fields)) missing += 1;
  return { total: records.length, missing, valid: records.length - missing };
}

function shannonEntropy(value: string): number {
  if (!value.length) return 0;
  const counts = new Map<string, number>();
  for (const c of value) counts.set(c, (counts.get(c) ?? 0) + 1);
  let h = 0;
  for (const count of counts.values()) {
    const p = count / value.length;
    h -= p * Math.log2(p);
  }
  return h;
}

export function findHighEntropySecrets(text: string, minLength = 20, minEntropy = 3.5): { tokenLength: number; entropy: number }[] {
  const candidates = text.match(/[A-Za-z0-9_\-+/=]{20,}/g) ?? [];
  return candidates
    .map((token) => ({ tokenLength: token.length, entropy: shannonEntropy(token) }))
    .filter((x) => x.entropy >= minEntropy);
}
