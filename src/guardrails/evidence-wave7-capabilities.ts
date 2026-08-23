import { createHash } from 'node:crypto';

function canonical(value: unknown): string {
  if (value === null || typeof value !== 'object') return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(canonical).join(',')}]`;
  return `{${Object.entries(value as Record<string, unknown>).sort(([a],[b]) => a.localeCompare(b)).map(([k,v]) => `${JSON.stringify(k)}:${canonical(v)}`).join(',')}}`;
}

export function hashApprovalRecord(record: Record<string, unknown>): string {
  return createHash('sha256').update(canonical(record)).digest('hex');
}
export function verifyApprovalRecordHash(record: Record<string, unknown>, expectedHash: string): boolean {
  return hashApprovalRecord(record) === expectedHash;
}

export type ClaimLease = { projectKey: string; taskKey: string; owner: string; expiresAt: string };
export type AllowlistEntry = { tool: string; actions: readonly string[] };
export function authorizeClaimedAction(input: { projectKey: string; taskKey: string; tool: string; action: string; owner: string; now: string }, claim: ClaimLease | null, allowlist: readonly AllowlistEntry[]): { ok: true } | { ok: false; reason: string } {
  if (!claim) return { ok: false, reason: 'CLAIM_MISSING' };
  if (claim.projectKey !== input.projectKey || claim.taskKey !== input.taskKey || claim.owner !== input.owner) return { ok: false, reason: 'CLAIM_MISMATCH' };
  if (Date.parse(claim.expiresAt) <= Date.parse(input.now)) return { ok: false, reason: 'CLAIM_EXPIRED' };
  const entry = allowlist.find(x => x.tool === input.tool);
  if (!entry?.actions.includes(input.action)) return { ok: false, reason: 'ACTION_NOT_ALLOWLISTED' };
  return { ok: true };
}

export type CompletenessViolation = { field: string; code: 'MISSING_COMPONENT'; message: string };
export function checkCompleteness(output: Record<string, unknown>, required: readonly string[]): { passed: boolean; violations: CompletenessViolation[] } {
  const violations = required.filter(k => output[k] === undefined || output[k] === null || output[k] === '').map(field => ({ field, code: 'MISSING_COMPONENT' as const, message: `Required component ${field} is missing.` }));
  return { passed: violations.length === 0, violations };
}

export type AuthzAuditEvent = { event: 'authorization_denied'; projectKey: string; taskKey: string; tool: string; action: string; reason: string; invocationId: string };
export function auditAuthorizationDenial(input: Omit<AuthzAuditEvent,'event'>): AuthzAuditEvent {
  if (!input.invocationId.trim()) throw new Error('INVOCATION_ID_REQUIRED');
  return { event: 'authorization_denied', ...input };
}

export type ActionEvidence = { invocationId: string; preconditions: { name: string; passed: boolean }[]; actionExecuted: boolean; outcome: 'executed'|'blocked' };
export function executeWithPreconditions(invocationId: string, checks: readonly { name: string; passed: boolean }[]): ActionEvidence {
  if (!invocationId.trim()) throw new Error('INVOCATION_ID_REQUIRED');
  const preconditions = checks.map(x => ({ ...x }));
  const allowed = preconditions.length > 0 && preconditions.every(x => x.passed);
  return { invocationId, preconditions, actionExecuted: allowed, outcome: allowed ? 'executed' : 'blocked' };
}

export function validateAtomicClaimLinkage(input: { projectKey: string; taskKey: string; builderRunId: number; claim: ClaimLease | null }): { ok: true } | { ok: false; reason: string } {
  if (!input.claim) return { ok: false, reason: 'ATOMIC_CLAIM_REQUIRED' };
  if (input.claim.projectKey !== input.projectKey || input.claim.taskKey !== input.taskKey) return { ok: false, reason: 'ATOMIC_CLAIM_LINKAGE_INVALID' };
  if (!Number.isInteger(input.builderRunId) || input.builderRunId <= 0) return { ok: false, reason: 'BUILDER_RUN_ID_INVALID' };
  return { ok: true };
}
