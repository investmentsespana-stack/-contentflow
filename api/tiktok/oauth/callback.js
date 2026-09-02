import crypto from 'node:crypto';

const REDIRECT_URI = process.env.TIKTOK_OAUTH_REDIRECT_URI || 'https://investmentsespana.space/api/tiktok/oauth/callback';
const STATE_COOKIE = 'tiktok_oauth_state_binding';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  if (req.method !== 'GET') return res.status(405).send('Method Not Allowed');

  const { clientKey, clientSecret, mode } = getCredentials();
  if (!clientKey || !clientSecret) {
    console.error(`[tiktok-oauth] preflight=runtime_configuration_incomplete mode=${mode}`);
    return res.status(503).send(page('TikTok runtime configuration incomplete', `${escapeHtml(mode)} credentials are not configured.`));
  }

  const { code, state, error, error_description: errorDescription } = req.query || {};
  if (error) {
    clearStateBinding(res);
    console.error(`[tiktok-oauth] preflight=authorization_not_completed error=${sanitizeError(errorDescription || error)}`);
    return res.status(400).send(page('TikTok authorization not completed', escapeHtml(errorDescription || error)));
  }
  if (!code || !state) {
    clearStateBinding(res);
    console.error(`[tiktok-oauth] preflight=missing_oauth_response code=${Boolean(code)} state=${Boolean(state)}`);
    return res.status(400).send(page('Missing OAuth response', 'Authorization code or state is missing.'));
  }

  const browserBinding = readCookie(req, STATE_COOKIE);
  if (!browserBinding || !validateSignedState(state, clientSecret, mode, browserBinding)) {
    clearStateBinding(res);
    console.error(`[tiktok-oauth] preflight=invalid_expired_or_unbound_state mode=${mode}`);
    return res.status(400).send(page('Invalid or expired OAuth state', 'Start the TikTok authorization flow again.'));
  }
  clearStateBinding(res);

  let stage = 'exchange_code';
  try {
    const token = await exchangeCode({ code, clientKey, clientSecret });
    const grantedScopes = String(token.scope || '').split(',').map((s) => s.trim()).filter(Boolean).sort();

    stage = 'read_user_info';
    const user = await getUserInfo(token.access_token);

    stage = 'create_encrypted_demo_session';
    const encrypted = encryptSession({
      access_token: token.access_token,
      refresh_token: token.refresh_token,
      expires_at: Date.now() + Number(token.expires_in || 0) * 1000,
      refresh_expires_at: Date.now() + Number(token.refresh_expires_in || 0) * 1000,
      open_id: token.open_id,
      scope: grantedScopes,
      mode,
    }, clientSecret);

    const fingerprint = crypto.createHash('sha256').update(token.access_token).digest('hex').slice(0, 16);
    res.setHeader('Set-Cookie', [
      ...(res.getHeader('Set-Cookie') || []),
      `tiktok_demo_session=${encrypted}; Path=/api/tiktok; HttpOnly; Secure; SameSite=Lax; Max-Age=86400`,
    ]);

    const receipt = {
      schema: 'nexo.tiktok.oauth.connection.v1',
      status: 'connected_demo_session',
      mode,
      openId: token.open_id || null,
      displayName: user?.data?.user?.display_name || null,
      scopes: grantedScopes,
      tokenFingerprint: fingerprint,
      checkedAt: new Date().toISOString(),
    };

    console.info(`[tiktok-oauth] status=${receipt.status} mode=${mode} scopes=${grantedScopes.join(',') || 'none'}`);
    return res.status(200).send(page(
      'TikTok OAuth connected',
      `<pre>${escapeHtml(JSON.stringify(receipt, null, 2))}</pre><p><a href="/api/tiktok/demo">Continue to Content Posting demo</a></p>`
    ));
  } catch (err) {
    console.error(`[tiktok-oauth] stage=${stage} mode=${mode} error=${sanitizeError(err?.message || err)}`);
    return res.status(502).send(page('TikTok OAuth verification failed', `${escapeHtml(stage)}: ${escapeHtml(sanitizeError(err?.message || 'Unknown error'))}`));
  }
}

function getCredentials() {
  const requestedMode = String(process.env.TIKTOK_OAUTH_MODE || 'production').toLowerCase();
  const mode = requestedMode === 'sandbox' ? 'sandbox' : 'production';
  if (mode === 'sandbox') {
    return {
      mode,
      clientKey: process.env.TIKTOK_SANDBOX_CLIENT_KEY,
      clientSecret: process.env.TIKTOK_SANDBOX_CLIENT_SECRET,
    };
  }
  return {
    mode,
    clientKey: process.env.TIKTOK_CLIENT_KEY,
    clientSecret: process.env.TIKTOK_CLIENT_SECRET,
  };
}

async function exchangeCode({ code, clientKey, clientSecret }) {
  const body = new URLSearchParams({
    client_key: clientKey,
    client_secret: clientSecret,
    code: String(code),
    grant_type: 'authorization_code',
    redirect_uri: REDIRECT_URI,
  });
  const response = await fetch('https://open.tiktokapis.com/v2/oauth/token/', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Cache-Control': 'no-cache' },
    body,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data.error || !data.access_token) {
    throw new Error(`TikTok token exchange: ${data.error_description || data.error || `HTTP ${response.status}`}`);
  }
  return data;
}

async function getUserInfo(accessToken) {
  const response = await fetch('https://open.tiktokapis.com/v2/user/info/?fields=open_id,display_name,avatar_url', {
    headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' },
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data?.error?.code && data.error.code !== 'ok') {
    throw new Error(`TikTok user info: ${data?.error?.message || `HTTP ${response.status}`}`);
  }
  return data;
}

function validateSignedState(value, secret, expectedMode, browserBinding) {
  if (!value || typeof value !== 'string' || !value.includes('.') || !browserBinding) return false;
  const [payload, signature] = value.split('.', 2);
  const expected = crypto
    .createHmac('sha256', `contentflow-tiktok-state:${secret}`)
    .update(payload)
    .digest('base64url');
  try {
    const a = Buffer.from(signature, 'base64url');
    const b = Buffer.from(expected, 'base64url');
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return false;
    const parsed = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    const age = Date.now() - Number(parsed.iat);
    const expectedBinding = crypto.createHash('sha256').update(browserBinding).digest('base64url');
    const suppliedBinding = Buffer.from(String(parsed.bind || ''), 'utf8');
    const wantedBinding = Buffer.from(expectedBinding, 'utf8');
    const bindingMatches = suppliedBinding.length === wantedBinding.length && crypto.timingSafeEqual(suppliedBinding, wantedBinding);
    return Number.isFinite(Number(parsed.iat)) && age >= 0 && age <= 10 * 60 * 1000 && typeof parsed.nonce === 'string' && parsed.nonce.length >= 16 && String(parsed.mode || 'production') === expectedMode && bindingMatches;
  } catch {
    return false;
  }
}

function readCookie(req, name) {
  const header = String(req.headers?.cookie || '');
  for (const part of header.split(';')) {
    const index = part.indexOf('=');
    if (index < 0) continue;
    const key = part.slice(0, index).trim();
    if (key !== name) continue;
    return decodeURIComponent(part.slice(index + 1).trim());
  }
  return null;
}

function clearStateBinding(res) {
  const existing = res.getHeader('Set-Cookie');
  const cookies = Array.isArray(existing) ? existing : existing ? [existing] : [];
  res.setHeader('Set-Cookie', [
    ...cookies,
    `${STATE_COOKIE}=; Path=/api/tiktok/oauth; HttpOnly; Secure; SameSite=Lax; Max-Age=0`,
  ]);
}

function encryptSession(payload, secret) {
  const key = crypto.createHash('sha256').update(`contentflow-tiktok-demo-v1:${secret}`).digest();
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(payload), 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [iv, tag, ciphertext].map((b) => b.toString('base64url')).join('.');
}

function sanitizeError(value) {
  return String(value)
    .replace(/(access_token|refresh_token|client_secret)=[^&\s]+/gi, '$1=[redacted]')
    .replace(/(?:act|rft)\.[A-Za-z0-9._-]+/g, '[redacted-token]')
    .slice(0, 500);
}

function page(title, body) {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="robots" content="noindex,nofollow"><title>${escapeHtml(title)}</title></head><body><h1>${escapeHtml(title)}</h1><div>${body}</div><p>No TikTok access or refresh token is displayed on this page.</p></body></html>`;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}
