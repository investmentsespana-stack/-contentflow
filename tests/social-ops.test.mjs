import test from 'node:test';
import assert from 'node:assert/strict';
import { createSocialOpsReceipt } from '../src/platform/social-ops.mjs';

test('prepares supported platform task', async () => {
  const r = await createSocialOpsReceipt({ id:'t1', platform:'facebook', action:'prepare_publish', evidenceDir:'tmp-test-evidence/social-ops' });
  assert.equal(r.status, 'prepared');
  assert.equal(r.platform, 'facebook');
});

test('publish requires explicit approval', async () => {
  await assert.rejects(() => createSocialOpsReceipt({ platform:'instagram', action:'publish', evidenceDir:'tmp-test-evidence/social-ops' }), /approval_required/);
});

test('approved publish is ready for execution', async () => {
  const r = await createSocialOpsReceipt({ id:'t2', platform:'youtube', action:'publish', approved:true, evidenceDir:'tmp-test-evidence/social-ops' });
  assert.equal(r.status, 'ready_for_browser_or_api_execution');
  assert.equal(r.executionPolicy.browserFallback, true);
});
