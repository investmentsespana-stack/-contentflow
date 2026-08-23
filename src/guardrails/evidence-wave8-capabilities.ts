import ts from 'typescript';

export type SecretScanResult = { blocked: boolean; code?: 'INPUT_CONTAINS_SECRETS_OR_PII' };
export function handleSecretOrPiiInput(scan: { hasSecret: boolean; hasPii: boolean }): SecretScanResult {
  return scan.hasSecret || scan.hasPii ? { blocked: true, code: 'INPUT_CONTAINS_SECRETS_OR_PII' } : { blocked: false };
}

export function findDirectStorageInstantiations(sourceText: string): string[] {
  const sf = ts.createSourceFile('scan.ts', sourceText, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  const hits: string[] = [];
  const visit = (node: ts.Node): void => {
    if (ts.isNewExpression(node)) {
      const expr = node.expression.getText(sf);
      if (/Store$/.test(expr) || expr === 'PlatformStore') hits.push(expr);
    }
    ts.forEachChild(node, visit);
  };
  visit(sf);
  return hits;
}

export type QualityViolation = { type: string; message: string; builder_run_id: number; timestamp_utc_iso8601: string };
export function createQualityViolation(type: string, message: string, builderRunId: number, now = new Date()): QualityViolation {
  if (!type.trim() || !message.trim() || !Number.isInteger(builderRunId) || builderRunId <= 0) throw new Error('INVALID_QUALITY_VIOLATION');
  return { type, message, builder_run_id: builderRunId, timestamp_utc_iso8601: now.toISOString() };
}

export function validateQualityViolation(value: QualityViolation): boolean {
  return Boolean(value.type && value.message && Number.isInteger(value.builder_run_id) && value.builder_run_id > 0 && !Number.isNaN(Date.parse(value.timestamp_utc_iso8601)));
}

export function serializeViolation(value: QualityViolation): string {
  if (!validateQualityViolation(value)) throw new Error('QUALITY_VIOLATION_SCHEMA_INVALID');
  return JSON.stringify(value);
}
