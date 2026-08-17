export type RequiredFieldValidation =
  | { ok: true }
  | { ok: false; missing: string[] };

export function validateRequiredFields(
  input: Record<string, unknown>,
  requiredFields: readonly string[],
): RequiredFieldValidation {
  const missing = requiredFields.filter((field) => {
    if (!Object.prototype.hasOwnProperty.call(input, field)) return true;
    const value = input[field];
    return value === undefined || value === null;
  });

  return missing.length === 0 ? { ok: true } : { ok: false, missing };
}

export function assertRequiredFields(
  input: Record<string, unknown>,
  requiredFields: readonly string[],
): void {
  const result = validateRequiredFields(input, requiredFields);
  if (!result.ok) {
    throw new Error(`MISSING_REQUIRED_FIELDS:${result.missing.join(',')}`);
  }
}
