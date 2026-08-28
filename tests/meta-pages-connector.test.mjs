import test from 'node:test';
import assert from 'node:assert/strict';
import { verifyMetaPagesConnection } from '../src/platform/meta-pages-connector.mjs';

function fakeFetch(expectedToken = 'user-token') {
  return async (url) => {
    const parsed = new URL(url);
    assert.equal(parsed.pathname, '/v23.0/me/accounts');
    assert.equal(parsed.searchParams.get('access_token'), expectedToken);
    return {
      ok: true,
      status: 200,
      async json() {
        return {
          data: [
            {
              id: '123',
              name: 'Cygnus Academy AI',
              access_token: 'page-token-secret',
              tasks: ['CREATE_CONTENT', 'MODERATE', 'MESSAGING'],
            },
          ],
        };
      },
    };
  };
}

test('verifies a selected Meta Page without exposing access tokens', async () => {
  const receipt = await verifyMetaPagesConnection({
    userAccessToken: 'user-token',
    pageName: 'Cygnus Academy AI',
    graphVersion: 'v23.0',
  }, { fetchImpl: fakeFetch() });

  assert.equal(receipt.schema, 'nexo.meta.pages.connection.v1');
  assert.equal(receipt.status, 'connected');
  assert.equal(receipt.page.name, 'Cygnus Academy AI');
  assert.equal(receipt.page.hasPageAccessToken, true);
  assert.equal(receipt.mode, 'read_only_verification');
  assert.ok(receipt.userTokenFingerprint.startsWith('sha256:'));
  assert.equal(JSON.stringify(receipt).includes('user-token'), false);
  assert.equal(JSON.stringify(receipt).includes('page-token-secret'), false);
});

test('fails closed when user access token is missing', async () => {
  await assert.rejects(
    () => verifyMetaPagesConnection({ pageName: 'Cygnus Academy AI' }, { fetchImpl: fakeFetch() }),
    /user_access_token_required/,
  );
});
