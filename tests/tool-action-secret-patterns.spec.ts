import { expect, test } from '@playwright/test';
import {
  assertNoToolActionSecrets,
  scanToolActionSecrets,
} from '../src/guardrails/tool-action-secret-patterns';

test('detects common secret formats in tool action input and output', () => {
  const findings = scanToolActionSecrets(
    {
      aws: 'AKIA1234567890ABCDEF',
      github: 'ghp_123456789012345678901234567890123456',
      nested: { bearer: 'Bearer abcdefghijklmnopqrstuvwxyz0123456789' },
    },
    {
      openai: 'sk-abcdefghijklmnopqrstuvwxyz0123456789',
      slack: 'xoxb-1234567890-abcdefghij',
      privateKey: '-----BEGIN PRIVATE KEY-----',
    },
  );

  expect(findings.map((f) => f.pattern)).toEqual(
    expect.arrayContaining([
      'aws_access_key_id',
      'github_token',
      'bearer_token',
      'openai_key',
      'slack_token',
      'private_key',
    ]),
  );
  expect(findings.some((f) => f.direction === 'input')).toBeTruthy();
  expect(findings.some((f) => f.direction === 'output')).toBeTruthy();
});

test('does not expose the detected secret value in findings', () => {
  const secret = 'ghp_123456789012345678901234567890123456';
  const findings = scanToolActionSecrets({ token: secret }, null);
  expect(findings).toHaveLength(1);
  expect(JSON.stringify(findings)).not.toContain(secret);
});

test('detects generic secret assignments and high entropy candidates', () => {
  const findings = scanToolActionSecrets(
    { config: 'api_key=abcdefghijklmnopqrstuvwxyz0123456789' },
    { opaque: 'X7vN2pQ9mL4sR8tW1yK6zA3cD5fG0hJ2' },
  );
  expect(findings.map((f) => f.pattern)).toEqual(
    expect.arrayContaining(['generic_secret_assignment', 'high_entropy_secret_candidate']),
  );
});

test('allows ordinary action payloads without secrets', () => {
  expect(
    scanToolActionSecrets(
      { action: 'github.update_file', path: 'src/index.ts' },
      { ok: true, status: 'updated' },
    ),
  ).toEqual([]);
});

test('blocks execution when a secret is present', () => {
  expect(() =>
    assertNoToolActionSecrets(
      { password: 'password=abcdefghijklmnopqrstuvwxyz123456' },
      null,
    ),
  ).toThrow('TOOL_ACTION_SECRET_REJECTED');
});

test('representative known-format corpus has <0.1% false negative rate', () => {
  const corpus: string[] = [];
  for (let i = 0; i < 500; i += 1) {
    const suffix = i.toString(36).toUpperCase().padStart(16, 'A').slice(-16);
    corpus.push(`AKIA${suffix}`);
    corpus.push(`ghp_${i.toString(36).padStart(36, 'a')}`);
    corpus.push(`sk-${i.toString(36).padStart(36, 'b')}`);
    corpus.push(`github_pat_${i.toString(36).padStart(32, 'c')}`);
  }

  let missed = 0;
  for (const secret of corpus) {
    if (scanToolActionSecrets({ secret }, null).length === 0) missed += 1;
  }

  const falseNegativeRate = missed / corpus.length;
  expect(falseNegativeRate).toBeLessThan(0.001);
});
