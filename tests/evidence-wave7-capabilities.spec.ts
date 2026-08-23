import { expect, test } from '@playwright/test';
import { auditAuthorizationDenial, authorizeClaimedAction, checkCompleteness, executeWithPreconditions, hashApprovalRecord, validateAtomicClaimLinkage, verifyApprovalRecordHash } from '../src/guardrails/evidence-wave7-capabilities';

test('approval record hash rejects altered payload', () => {
  const record = { approvalId: 'a-1', projectKey: 'contentflow', approved: true, changeHash: 'abc' };
  const hash = hashApprovalRecord(record);
  expect(hash).toMatch(/^[a-f0-9]{64}$/);
  expect(verifyApprovalRecordHash(record, hash)).toBe(true);
  expect(verifyApprovalRecordHash({ ...record, approved: false }, hash)).toBe(false);
});

test('allowlist enforcement is bound to a valid atomic claim', () => {
  const claim = { projectKey:'contentflow', taskKey:'t1', owner:'agent-1', expiresAt:'2026-08-24T00:00:00Z' };
  const input = { projectKey:'contentflow', taskKey:'t1', owner:'agent-1', tool:'github', action:'read', now:'2026-08-23T00:00:00Z' };
  expect(authorizeClaimedAction(input, claim, [{ tool:'github', actions:['read'] }])).toEqual({ ok:true });
  expect(authorizeClaimedAction({ ...input, action:'delete' }, claim, [{ tool:'github', actions:['read'] }])).toEqual({ ok:false, reason:'ACTION_NOT_ALLOWLISTED' });
  expect(authorizeClaimedAction(input, null, [{ tool:'github', actions:['read'] }])).toEqual({ ok:false, reason:'CLAIM_MISSING' });
});

test('completeness checker returns structured violations for missing components', () => {
  expect(checkCompleteness({ summary:'ok' }, ['summary','evidence','decision'])).toEqual({
    passed:false,
    violations:[
      { field:'evidence', code:'MISSING_COMPONENT', message:'Required component evidence is missing.' },
      { field:'decision', code:'MISSING_COMPONENT', message:'Required component decision is missing.' },
    ],
  });
  expect(checkCompleteness({ summary:'ok', evidence:['e1'], decision:'go' }, ['summary','evidence','decision']).passed).toBe(true);
});

test('authorization denials produce structured invocation-linked audit records', () => {
  expect(auditAuthorizationDenial({ projectKey:'contentflow', taskKey:'t1', tool:'github', action:'merge', reason:'CLAIM_EXPIRED', invocationId:'inv-42' })).toEqual({ event:'authorization_denied', projectKey:'contentflow', taskKey:'t1', tool:'github', action:'merge', reason:'CLAIM_EXPIRED', invocationId:'inv-42' });
});

test('preconditions fail closed and emit invocation-linked structured evidence', () => {
  const blocked = executeWithPreconditions('inv-1', [{ name:'claim_valid', passed:true }, { name:'approval_valid', passed:false }]);
  expect(blocked).toEqual({ invocationId:'inv-1', preconditions:[{ name:'claim_valid', passed:true },{ name:'approval_valid', passed:false }], actionExecuted:false, outcome:'blocked' });
  const executed = executeWithPreconditions('inv-2', [{ name:'claim_valid', passed:true }]);
  expect(executed.actionExecuted).toBe(true);
});

test('atomic claim linkage rejects missing or mismatched dependencies', () => {
  const claim = { projectKey:'contentflow', taskKey:'t1', owner:'agent', expiresAt:'2026-08-24T00:00:00Z' };
  expect(validateAtomicClaimLinkage({ projectKey:'contentflow', taskKey:'t1', builderRunId:3660, claim })).toEqual({ ok:true });
  expect(validateAtomicClaimLinkage({ projectKey:'contentflow', taskKey:'t1', builderRunId:3660, claim:null })).toEqual({ ok:false, reason:'ATOMIC_CLAIM_REQUIRED' });
  expect(validateAtomicClaimLinkage({ projectKey:'contentflow', taskKey:'other', builderRunId:3660, claim })).toEqual({ ok:false, reason:'ATOMIC_CLAIM_LINKAGE_INVALID' });
});
