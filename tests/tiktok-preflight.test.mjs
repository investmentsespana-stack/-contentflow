import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import uploadHandler from '../api/tiktok/upload.js';

const ORIGINAL_ENV = { ...process.env };
const ORIGINAL_FETCH = globalThis.fetch;

function encryptSession(payload, secret) {
  const key = crypto.createHash('sha256').update(`contentflow-tiktok-demo-v1:${secret}`).digest();
  const iv = Buffer.alloc(12, 7);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(payload), 'utf8'), cipher.final()]);
  return [iv, cipher.getAuthTag(), ciphertext].map((value) => value.toString('base64url')).join('.');
}

function makeRes() {
  return {
    statusCode: 200,
    body: null,
    setHeader() {},
    status(code) { this.statusCode = code; return this; },
    json(body) { this.body = body; return this; },
  };
}

test.afterEach(() => {
  process.env = { ...ORIGINAL_ENV };
  globalThis.fetch = ORIGINAL_FETCH;
});

test('safe preflight initializes once and uploads zero media bytes', async () => {
  process.env.TIKTOK_OAUTH_MODE = 'sandbox';
  process.env.TIKTOK_SANDBOX_CLIENT_SECRET = 'sandbox-secret';
  const cookie = encryptSession({
    access_token: 'test-access-token',
    expires_at: Date.now() + 60_000,
    open_id: 'cygnus-open-id',
    scope: ['user.info.basic', 'video.upload'],
    mode: 'sandbox',
  }, 'sandbox-secret');

  const calls = [];
  globalThis.fetch = async (url, options) => {
    calls.push({ url: String(url), method: options.method, body: JSON.parse(options.body) });
    return new Response(JSON.stringify({
      data: { publish_id: 'preflight-publish-id', upload_url: 'https://open-upload.tiktokapis.com/preflight-secret' },
      error: { code: 'ok' },
    }), { status: 200, headers: { 'content-type': 'application/json' } });
  };

  const res = makeRes();
  await uploadHandler({ method: 'POST', query: { mode: 'preflight' }, headers: { cookie: `tiktok_demo_session=${cookie}` } }, res);

  assert.equal(res.statusCode, 200);
  assert.equal(calls.length, 1);
  assert.equal(calls[0].method, 'POST');
  assert.match(calls[0].url, /\/inbox\/video\/init\/$/);
  assert.equal(res.body.status, 'upload_session_initialized');
  assert.equal(res.body.contentBytesUploaded, 0);
  assert.equal(res.body.publicPostsCreated, 0);
  assert.equal(JSON.stringify(res.body).includes('open-upload.tiktokapis.com'), false);
});

test('safe preflight rejects a session without video.upload', async () => {
  process.env.TIKTOK_OAUTH_MODE = 'sandbox';
  process.env.TIKTOK_SANDBOX_CLIENT_SECRET = 'sandbox-secret';
  const cookie = encryptSession({
    access_token: 'test-access-token',
    expires_at: Date.now() + 60_000,
    scope: ['user.info.basic'],
    mode: 'sandbox',
  }, 'sandbox-secret');
  globalThis.fetch = async () => { throw new Error('must not fetch'); };

  const res = makeRes();
  await uploadHandler({ method: 'POST', query: { mode: 'preflight' }, headers: { cookie: `tiktok_demo_session=${cookie}` } }, res);
  assert.equal(res.statusCode, 403);
  assert.match(res.body.error, /video\.upload/);
});
