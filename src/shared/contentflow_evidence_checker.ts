export const EVIDENCE_FIELDS = [
  'extracted_text',
  'structured_data',
  'metadata',
  'annotations',
  'validation_results',
  'source_references',
] as const;

function nonempty(value: unknown): boolean {
  if (value === null || value === undefined) return false;
  if (typeof value === 'boolean') return value;
  if (typeof value === 'string') return value.trim().length > 0;
  if (typeof value === 'number') return value !== 0;
  if (Array.isArray(value)) return value.length > 0;
  if (value instanceof Set || value instanceof Map) return value.size > 0;
  if (typeof value === 'object') return Object.keys(value as Record<string, unknown>).length > 0;
  return true;
}

export function hasEvidence(reviewOutput: Record<string, unknown> | null | undefined): boolean {
  if (!reviewOutput || Object.keys(reviewOutput).length === 0) return false;
  return EVIDENCE_FIELDS.some((field) => nonempty(reviewOutput[field]));
}
