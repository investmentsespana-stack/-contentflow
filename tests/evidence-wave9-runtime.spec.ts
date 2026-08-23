import { expect, test } from '@playwright/test';
import { CorrelatedEvidenceRecorder, computeCoherenceScore, enforceOutputCompletion, verifyRollbackPlan } from '../src/guardrails/evidence-wave9-runtime';

test('output completion fails closed without review, evidence, or verifiable claims', () => {
  const goodClaim = { id:'c1', kind:'runtime' as const, statement:'Run passed.', evidenceRefs:['event:1'] };
  expect(enforceOutputCompletion({ reviewApproved:false,evidenceRefs:['e1'],claims:[goodClaim] })).toEqual({allowed:false,reason:'VALID_REVIEW_REQUIRED'});
  expect(enforceOutputCompletion({ reviewApproved:true,evidenceRefs:[],claims:[goodClaim] })).toEqual({allowed:false,reason:'PERSISTED_EVIDENCE_REQUIRED'});
  expect(enforceOutputCompletion({ reviewApproved:true,evidenceRefs:['e1'],claims:[{id:'bad',kind:'fact',statement:'Unsupported.'}] })).toEqual({allowed:false,reason:'NON_VERIFIABLE_CLAIMS'});
  expect(enforceOutputCompletion({ reviewApproved:true,evidenceRefs:['e1'],claims:[goodClaim] })).toEqual({allowed:true});
});

test('coherence score uses lexical cosine NLP and discourse continuity', () => {
  const coherent = computeCoherenceScore(['The deployment service validates evidence before completion.','Therefore the deployment service blocks completion without evidence.','Then the deployment service records evidence before completion.']);
  const incoherent = computeCoherenceScore(['The deployment service validates evidence.','Bananas orbit silently across purple equations.','A violin measures database weather.']);
  expect(coherent).toBeGreaterThan(incoherent);
  expect(coherent).toBeGreaterThan(0.35);
  expect(incoherent).toBeLessThan(0.15);
});

test('rollback schema violations must produce a durable evidence id', async () => {
  const recorder = new CorrelatedEvidenceRecorder(3668, async event => event.event === 'rollback_schema_violation' ? 'ledger:rollback:1' : '');
  const result = await verifyRollbackPlan({ target:'stable' }, { required:['target','restore_command'] }, recorder);
  expect(result).toEqual({ok:false,missing:['restore_command'],evidenceId:'ledger:rollback:1'});
  expect(recorder.events[0]).toMatchObject({event:'rollback_schema_violation',builder_run_id:3668,evidence_id:'ledger:rollback:1'});
});

test('rollback integration correlates evidence to builder run and passes valid plans', async () => {
  const persisted: Record<string,unknown>[]=[];
  const recorder = new CorrelatedEvidenceRecorder(3669, async event => { persisted.push(event); return 'ledger:3669:1'; });
  const invalid = await verifyRollbackPlan({ target:'stable' }, { required:['target','restore_command'] }, recorder);
  expect(invalid.ok).toBe(false);
  expect(persisted).toHaveLength(1);
  expect(persisted[0]).toMatchObject({builder_run_id:3669,event:'rollback_schema_violation'});
  expect(await verifyRollbackPlan({target:'stable',restore_command:'restore-safe'}, {required:['target','restore_command']}, recorder)).toEqual({ok:true});
});
