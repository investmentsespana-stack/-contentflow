import { readFile, readdir, stat } from 'node:fs/promises';
import { extname, join, relative, basename } from 'node:path';

// Reports only file, line and pattern class; matched secret values are never emitted.
const ROOTS = ['.'];
const TEXT_EXTENSIONS = new Set(['.sql', '.ts', '.tsx', '.js', '.mjs', '.json', '.yml', '.yaml', '.toml']);
const MAX_BYTES = 2_000_000;
const SKIP_DIR_NAMES = new Set(['.git', 'node_modules', 'tests', 'docs', 'certification-evidence', 'playwright-report', 'test-results']);

const PATTERNS = [
  ['private_key', /-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/g],
  ['github_token', /\bgh[pousr]_[A-Za-z0-9_]{20,}\b/g],
  ['openai_key', /\bsk-[A-Za-z0-9_-]{20,}\b/g],
  ['aws_access_key', /\bAKIA[0-9A-Z]{16}\b/g],
  ['bearer_token', /\bBearer\s+[A-Za-z0-9._~+\/-]{20,}=*\b/gi],
  ['jwt', /\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b/g],
  ['supabase_service_role_assignment', /(?:SUPABASE_SERVICE_ROLE_KEY|service_role_key)\s*[:=]\s*["']?[A-Za-z0-9._-]{20,}/gi],
  ['generic_secret_assignment', /(?:api[_-]?key|secret|token|password)\s*[:=]\s*["'][^"'\n]{16,}["']/gi],
];

async function collect(path) {
  const info = await stat(path);
  if (info.isFile()) return [path];
  if (SKIP_DIR_NAMES.has(basename(path))) return [];
  const out = [];
  for (const entry of await readdir(path)) out.push(...await collect(join(path, entry)));
  return out;
}

export async function scanDeploymentArtifacts(root = process.cwd()) {
  const files = [];
  for (const dir of ROOTS) files.push(...await collect(join(root, dir)));

  const scanned = [];
  const findings = [];
  for (const file of files.sort()) {
    const rel = relative(root, file).replaceAll('\\', '/');
    if (!TEXT_EXTENSIONS.has(extname(file))) continue;
    const info = await stat(file);
    if (info.size > MAX_BYTES) continue;
    const text = await readFile(file, 'utf8');
    scanned.push(rel);
    for (const [pattern, regex] of PATTERNS) {
      regex.lastIndex = 0;
      let match;
      while ((match = regex.exec(text)) !== null) {
        const line = text.slice(0, match.index).split('\n').length;
        findings.push({ file: rel, line, pattern });
        if (match.index === regex.lastIndex) regex.lastIndex += 1;
      }
    }
  }

  return {
    schemaVersion: 1,
    passed: findings.length === 0,
    roots: ROOTS,
    excludedDirectories: [...SKIP_DIR_NAMES].sort(),
    scannedFileCount: scanned.length,
    scannedFiles: scanned,
    findings,
    secretValuesExposed: false,
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const report = await scanDeploymentArtifacts();
  process.stdout.write(`${JSON.stringify(report, null, 2)}\n`);
  if (!report.passed) process.exitCode = 2;
}
