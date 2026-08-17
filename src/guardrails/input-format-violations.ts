export const INPUT_FORMAT_SPEC = 'ContentFlow API Input Format Rules v1';

export type FormatViolationCondition = {
  id: string;
  category: 'format_violation';
  rule: string;
  rationale: string;
};

/**
 * Canonical list of syntactic/structural input failures for ContentFlow.
 * These conditions are intentionally limited to wire-format and structural
 * validity so they do not overlap with missing-field, secret, assumption,
 * semantic/domain, or authorization rejections.
 */
export const FORMAT_VIOLATION_CONDITIONS: readonly FormatViolationCondition[] = [
  {
    id: 'malformed_json',
    category: 'format_violation',
    rule: 'IFR-001: Request bodies declared as JSON must parse as RFC 8259 JSON.',
    rationale: 'Malformed JSON is a syntax failure under IFR-001, so it is classified as format_violation.',
  },
  {
    id: 'root_not_object',
    category: 'format_violation',
    rule: 'IFR-002: ContentFlow command payloads must have a JSON object at the root.',
    rationale: 'A scalar or array root violates the structural root rule IFR-002, so it is classified as format_violation.',
  },
  {
    id: 'invalid_uuid_format',
    category: 'format_violation',
    rule: 'IFR-003: Fields declared as UUID must use canonical 8-4-4-4-12 hexadecimal UUID text.',
    rationale: 'A UUID-shaped field that does not match IFR-003 is structurally invalid and is classified as format_violation.',
  },
  {
    id: 'invalid_iso8601_timestamp',
    category: 'format_violation',
    rule: 'IFR-004: Timestamp fields must be RFC 3339 / ISO 8601 date-time strings with timezone information.',
    rationale: 'A timestamp that cannot be parsed under IFR-004 is a wire-format failure and is classified as format_violation.',
  },
  {
    id: 'wrong_scalar_type',
    category: 'format_violation',
    rule: 'IFR-005: Scalar fields must match their declared primitive JSON type (string, number, integer, boolean, null).',
    rationale: 'Supplying the wrong primitive JSON type violates IFR-005 and is classified as format_violation.',
  },
  {
    id: 'wrong_container_type',
    category: 'format_violation',
    rule: 'IFR-006: Object fields must be JSON objects and list fields must be JSON arrays.',
    rationale: 'Using an object where an array is declared, or vice versa, violates IFR-006 and is classified as format_violation.',
  },
  {
    id: 'invalid_array_item_shape',
    category: 'format_violation',
    rule: 'IFR-007: Every array element must match the structural type declared for that collection.',
    rationale: 'An array element with the wrong structural shape violates IFR-007 and is classified as format_violation.',
  },
  {
    id: 'invalid_encoded_string_format',
    category: 'format_violation',
    rule: 'IFR-008: Fields declared with a textual encoding (for example URI, email, base64, or date) must satisfy that encoding grammar.',
    rationale: 'A value that fails its declared textual encoding grammar violates IFR-008 and is classified as format_violation.',
  },
] as const;

export function classifyFormatViolation(conditionId: string): FormatViolationCondition | null {
  return FORMAT_VIOLATION_CONDITIONS.find((condition) => condition.id === conditionId) ?? null;
}
