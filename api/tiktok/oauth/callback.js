import crypto from 'node:crypto';

const REDIRECT_URI = process.env.TIKTOK_OAUTH_REDIRECT_URI || 'https://investmentsespana.space/api/tiktok/oauth/callback';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  if (req.method !== 'GET') return res.status(405).send('Method Not Allowed');

  const clientKey = process.env.TIKTOK_CLIENT_KEY;
  const clientSecret = process.env.TIKTOK_CLIENT_SECRET;
  if (!clientKey || !clientSecret) return res.status(503).send(page('TikTok runtime configuration incomplete', 'Client credentials are not configured.'));

  const { code, state, error, error_description: errorDescription } = req.query || {};
  if (error) return res.status(400).send(page('TikTok authorization not completed', escapeHtml(errorDescription || error)));
  if (!code || !state) return res.status(400).send(page('Missing OAuth response', 'Authorization code or state is missing.'));

  const cookies = parseCookies(req.headers.cookie || '');
  const expectedState = cookies.tiktok_oauth_state;
  if (!expectedState || !validateStateCookie(expectedState, state, clientSecret)) {
    return res.status(400).send(page('Invalid or expired OAuth state', 'Start the TikTok authorization flow again.'));
  }

  try {
    const token = await exchangeCode({ code, clientKey, clientSecret });
    const grantedScopes = String(token.scope || '').split(',').map((s) => s.trim()).filter(Boolean).sort();

    const user = await getUserInfo(token.access_token);
    const encrypted = encryptSession({
      access_token: token.access_token,
      refresh_token: token.refresh_token,
      expires_at: Date.now() + Number(token.expires_in || 0) * 1000,
      refresh_expires_at: Date.now() + Number(token.refresh_expires_in || 0) * 1000,
      open_id: token.open_id,
      scope: grantedScopes,
    }, clientSecret);

    const fingerprint = crypto.createHash('sha256').update(token.access_token).digest('hex').slice(0, 16);
    res.setHeader('Set-Cookie', [
      `tiktok_demo_session=${encrypted}; Path=/api/tiktok; HttpOnly; Secure; SameSite=Lax; Max-Age=86400`,
      'tiktok_oauth_state=; Path=/api/tiktok; HttpOnly; Secure; SameSite=Lax; Max-Age=0',
    ]);

    const receipt = {
      schema: 'nexo.tiktok.oauth.connection.v1',
      status: 'connected_demo_session',
      openId: token.open_id || null,
      displayName: user?.data?.user?.display_name || null,
      scopes: grantedScopes,
      tokenFingerprint: fingerprint,
      checkedAt: new Date().toISOString(),
    };

    return res.status(200).send(page(
      'TikTok OAuth connected',
      `<pre>${escapeHtml(JSON.stringify(receipt, null, 2))}</pre><p><a href="/api/tiktok/demo">Continue to Content Posting demo</a></p>`
    ));
  } catch (err) {
    console.error(`[tiktok-oauth] ${sanitizeError(err?.message || err)}`);
    return res.status(502).send(page('TikTok OAuth verification failed', escapeHtml(sanitizeError(err?.message || 'Unknown error'))));
  }
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

function validateStateCookie(cookieValue, returnedState, secret) {
  const [state, sig] = String(cookieValue).split('.', 2);
  if (!state || !sig || state !== returnedState) return false;
  const expected = crypto.createHmac('sha256', `contentflow-tiktok-state:${secret}`).update(state).digest('base64url');
  try {
    const a = Buffer.from(sig, 'base64url');
    const b = Buffer.from(expected, 'base64url');
    return a.length === b.length && crypto.timingSafeEqual(a, b);
  } catch {
    return false;
  }
}

function encryptSession(payload, secret) {
  const key = crypto.createHash('sha256').update(`contentflow-tiktok-demo-v1:${secret}`).digest();
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(payload), 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [iv, tag, ciphertext].map((b) => b.toString('base64url')).join('.');
}

function parseCookies(header) {
  return header.split(';').reduce((acc, item) => {
    const index = item.indexOf('=');
    if (index > -1) acc[item.slice(0, index).trim()] = item.slice(index + 1).trim();
    return acc;
  }, {});
}

function sanitizeError(value) {
  return String(value)
    .replace(/(access_token|refresh_token)=[^&\s]+/gi, '$1=[redacted]')
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
