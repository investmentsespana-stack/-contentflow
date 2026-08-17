export type SensitiveInputFinding = {
  kind: 'secret' | 'pii';
  pattern: string;
  path: string;
};

export type SensitiveInputScanResult =
  | { ok: true; findings: [] }
  | { ok: false; findings: SensitiveInputFinding[] };

type PatternRule = {
  kind: 'secret' | 'pii';
  name: string;
  regex: RegExp;
};

const RULES: readonly PatternRule[] = [
  { kind: 'secret', name: 'aws_access_key_id', regex: /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g },
  { kind: 'secret', name: 'github_token', regex: /\bgh(?:p|o|u|s|r)_[A-Za-z0-9_]{20,255}\b/g },
  { kind: 'secret', name: 'jwt', regex: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g },
  { kind: 'secret', name: 'bearer_token', regex: /\bBearer\s+[A-Za-z0-9._~+\/-]{20,}\b/gi },
  { kind: 'secret', name: 'private_key', regex: /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g },
  { kind: 'pii', name: 'email', regex: /\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b/gi },
  { kind: 'pii', name: 'us_ssn', regex: /\b(?!000|666|9\d\d)\d{3}[- ](?!00)\d{2}[- ](?!0000)\d{4}\b/g },
  { kind: 'pii', name: 'us_phone', regex: /\b(?:\+?1[-. ]?)?(?:\([2-9]\d{2}\)|[2-9]\d{2})[-. ]?[2-9]\d{2}[-. ]?\d{4}\b/g },
];

function collectStrings(value: unknown, path = '$', out: Array<{ path: string; value: string }> = []) {
  if (typeof value === 'string') {
    out.push({ path, value });
    return out;
  }
  if (Array.isArray(value)) {
    value.forEach((item, index) => collectStrings(item, `${path}[${index}]`, out));
    return out;
  }
  if (value && typeof value === 'object') {
    Object.entries(value as Record<string, unknown>).forEach(([key, item]) =>
      collectStrings(item, `${path}.${key}`, out),
    );
  }
  return out;
}

export function scanSensitiveInput(input: unknown): SensitiveInputScanResult {
  const findings: SensitiveInputFinding[] = [];

  for (const item of collectStrings(input)) {
    for (const rule of RULES) {
      rule.regex.lastIndex = 0;
      if (rule.regex.test(item.value)) {
        findings.push({ kind: rule.kind, pattern: rule.name, path: item.path });
      }
    }
  }

  return findings.length === 0 ? { ok: true, findings: [] } : { ok: false, findings };
}

export function assertNoSensitiveInput(input: unknown): void {
  const result = scanSensitiveInput(input);
  if (!result.ok) {
    const summary = result.findings.map((f) => `${f.kind}:${f.pattern}@${f.path}`).join(',');
    throw new Error(`SENSITIVE_INPUT_REJECTED:${summary}`);
  }
}
