export type ToolSecretFinding = {
  direction: 'input' | 'output';
  pattern: string;
  path: string;
};

type SecretRule = { name: string; regex: RegExp };

const SECRET_RULES: readonly SecretRule[] = [
  { name: 'aws_access_key_id', regex: /\b(?:AKIA|ASIA)[A-Z0-9]{16}\b/g },
  { name: 'github_token', regex: /\bgh(?:p|o|u|s|r)_[A-Za-z0-9_]{20,255}\b/g },
  { name: 'github_fine_grained_pat', regex: /\bgithub_pat_[A-Za-z0-9_]{20,255}\b/g },
  { name: 'openai_key', regex: /\bsk-[A-Za-z0-9_-]{20,200}\b/g },
  { name: 'stripe_secret', regex: /\bsk_(?:live|test)_[A-Za-z0-9]{16,}\b/g },
  { name: 'slack_token', regex: /\bxox[baprs]-[A-Za-z0-9-]{10,}\b/g },
  { name: 'jwt', regex: /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g },
  { name: 'bearer_token', regex: /\bBearer\s+[A-Za-z0-9._~+\/-]{20,}\b/gi },
  { name: 'private_key', regex: /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g },
  { name: 'generic_secret_assignment', regex: /\b(?:api[_-]?key|secret|token|password)\s*[:=]\s*["']?[A-Za-z0-9._~+\/-]{20,}["']?/gi },
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

function shannonEntropy(value: string): number {
  if (!value) return 0;
  const counts = new Map<string, number>();
  for (const ch of value) counts.set(ch, (counts.get(ch) ?? 0) + 1);
  let entropy = 0;
  for (const count of counts.values()) {
    const p = count / value.length;
    entropy -= p * Math.log2(p);
  }
  return entropy;
}

function hasHighEntropySecretCandidate(value: string): boolean {
  const candidates = value.match(/[A-Za-z0-9+/_=-]{32,128}/g) ?? [];
  return candidates.some((candidate) => {
    if (/^[A-F0-9]{32,}$/i.test(candidate)) return false;
    return shannonEntropy(candidate) >= 4.2;
  });
}

function scanDirection(direction: 'input' | 'output', payload: unknown): ToolSecretFinding[] {
  const findings: ToolSecretFinding[] = [];
  for (const item of collectStrings(payload)) {
    let matched = false;
    for (const rule of SECRET_RULES) {
      rule.regex.lastIndex = 0;
      if (rule.regex.test(item.value)) {
        findings.push({ direction, pattern: rule.name, path: item.path });
        matched = true;
      }
    }
    if (!matched && hasHighEntropySecretCandidate(item.value)) {
      findings.push({ direction, pattern: 'high_entropy_secret_candidate', path: item.path });
    }
  }
  return findings;
}

export function scanToolActionSecrets(input: unknown, output: unknown): ToolSecretFinding[] {
  return [...scanDirection('input', input), ...scanDirection('output', output)];
}

export function assertNoToolActionSecrets(input: unknown, output: unknown): void {
  const findings = scanToolActionSecrets(input, output);
  if (findings.length > 0) {
    const summary = findings.map((f) => `${f.direction}:${f.pattern}@${f.path}`).join(',');
    throw new Error(`TOOL_ACTION_SECRET_REJECTED:${summary}`);
  }
}
