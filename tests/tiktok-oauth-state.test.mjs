import test from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import startHandler from '../api/tiktok/oauth/start.js';
import callbackHandler from '../api/tiktok/oauth/callback.js';

const ORIGINAL_ENV = { ...process.env };
const ORIGINAL_FETCH = globalThis.fetch;

function configure(mode = 'sandbox') {
  process.env.TIKTOK_OAUTH_MODE = mode;
  process.env.TIKTOK_SANDBOX_CLIENT_KEY = 'sandbox-key';
  process.env.TIKTOK_SANDBOX_CLIENT_SECRET = 'sandbox-secret';
  process.env.TIKTOK_CLIENT_KEY = 'production-key';
  process.env.TIKTOK_CLIENT_SECRET = 'production-secret';
  process.env.TIKTOK_OAUTH_REDIRECT_URI = 'https://investmentsespana.space/api/tiktok/oauth/callback';
}

function makeRes() {
  const headers = new Map();
  return {
    statusCode: 200,
    body: '',
    redirectUrl: null,
    setHeader(name, value) { headers.set(String(name).toLowerCase(), value); },
    getHeader(name) { return headers.get(String(name).toLowerCase()); },
    status(code) { this.statusCode = code; return this; },
    send(body) { this.body = String(body); return this; },
    redirect(code, url) { this.statusCode = code; this.redirectUrl = url; return this; },
  };
}

async function issueState(mode = 'sandbox') {
  configure(mode);
  const res = makeRes();
  await startHandler({ method: 'GET' }, res);
  assert.equal(res.statusCode, 302);
  const url = new URL(res.redirectUrl);
  const state = url.searchParams.get('state');
  const cookieHeader = res.getHeader('Set-Cookie');
  const raw = Array.isArray(cookieHeader) ? cookieHeader[0] : cookieHeader;
  const cookiePair = raw.split(';', 1)[0];
  const binding = decodeURIComponent(cookiePair.split('=').slice(1).join('='));
  return { state, cookiePair, binding, startRes: res };
}

function resignState(state, secret, patch) {
  const [payload] = state.split('.', 2);
  const parsed = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
  Object.assign(parsed, patch);
  const nextPayload = Buffer.from(JSON.stringify(parsed)).toString('base64url');
  const signature = crypto
    .createHmac('sha256', `contentflow-tiktok-state:${secret}`)
    .update(nextPayload)
    .digest('base64url');
  return `${nextPayload}.${signature}`;
}

function mockSuccessfulTikTok() {
  let calls = 0;
  globalThis.fetch = async (url) => {
    calls += 1;
    if (String(url).includes('/oauth/token/')) {
      return new Response(JSON.stringify({
        access_token: 'test-access-token',
        refresh_token: 'test-refresh-token',
        expires_in: 3600,
        refresh_expires_in: 86400,
        open_id: 'test-open-id',
        scope: 'video.upload,user.info.basic',
      }), { status: 200, headers: { 'content-type': 'application/json' } });
    }
    return new Response(JSON.stringify({ data: { user: { display_name: 'Cygnus Test' } }, error: { code: 'ok' } }), {
      status: 200,
      headers: { 'content-type': 'application/json' },
    });
  };
  return () => calls;
}

async function callCallback({ state, cookiePair = '', mode = 'sandbox' }) {
  configure(mode);
  const res = makeRes();
  await callbackHandler({
    method: 'GET',
    query: { code: 'dummy-code', state },
    headers: { cookie: cookiePair },
  }, res);
  return res;
}

test.afterEach(() => {
  process.env = { ...ORIGINAL_ENV };
  globalThis.fetch = ORIGINAL_FETCH;
});

test('start issues browser-bound signed state and hardened short-lived cookie', async () => {
  const { state, startRes } = await issueState();
  assert.match(state, /^[^.]+\.[^.]+$/);
  const cookies = startRes.getHeader('Set-Cookie');
  const serialized = Array.isArray(cookies) ? cookies.join('\n') : String(cookies);
  assert.match(serialized, /tiktok_oauth_state_binding=/);
  assert.match(serialized, /HttpOnly/);
  assert.match(serialized, /Secure/);
  assert.match(serialized, /SameSite=Lax/);
  assert.match(serialized, /Max-Age=600/);
});

test('valid browser-bound state reaches token exchange and consumes binding cookie', async () => {
  const issued = await issueState();
  const calls = mockSuccessfulTikTok();
  const res = await callCallback(issued);
  assert.equal(res.statusCode, 200);
  assert.equal(calls(), 2);
  const cookies = res.getHeader('Set-Cookie');
  const serialized = Array.isArray(cookies) ? cookies.join('\n') : String(cookies);
  assert.match(serialized, /tiktok_oauth_state_binding=.*Max-Age=0/);
  assert.match(serialized, /tiktok_demo_session=/);
});

test('missing browser binding rejects before token exchange', async () => {
  const issued = await issueState();
  let calls = 0;
  globalThis.fetch = async () => { calls += 1; throw new Error('must not fetch'); };
  const res = await callCallback({ ...issued, cookiePair: '' });
  assert.equal(res.statusCode, 400);
  assert.equal(calls, 0);
  assert.match(res.body, /Invalid or expired OAuth state/);
});

test('mismatched browser binding rejects before token exchange', async () => {
  const issued = await issueState();
  let calls = 0;
  globalThis.fetch = async () => { calls += 1; throw new Error('must not fetch'); };
  const res = await callCallback({ ...issued, cookiePair: 'tiktok_oauth_state_binding=wrong-binding' });
  assert.equal(res.statusCode, 400);
  assert.equal(calls, 0);
});

test('expired signed state rejects before token exchange', async () => {
  const issued = await issueState();
  const expired = resignState(issued.state, 'sandbox-secret', { iat: Date.now() - (11 * 60 * 1000) });
  let calls = 0;
  globalThis.fetch = async () => { calls += 1; throw new Error('must not fetch'); };
  const res = await callCallback({ ...issued, state: expired });
  assert.equal(res.statusCode, 400);
  assert.equal(calls, 0);
});

test('sandbox state is rejected when callback runtime is production', async () => {
  const issued = await issueState('sandbox');
  let calls = 0;
  globalThis.fetch = async () => { calls += 1; throw new Error('must not fetch'); };
  const res = await callCallback({ ...issued, mode: 'production' });
  assert.equal(res.statusCode, 400);
  assert.equal(calls, 0);
});
