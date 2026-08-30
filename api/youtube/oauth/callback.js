import crypto from 'node:crypto';

const REDIRECT_URI = process.env.YOUTUBE_OAUTH_REDIRECT_URI || 'https://investmentsespana.space/api/youtube/oauth/callback';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  if (req.method !== 'GET') return res.status(405).send('Method Not Allowed');

  const clientId = process.env.YOUTUBE_CLIENT_ID;
  const clientSecret = process.env.YOUTUBE_CLIENT_SECRET;
  if (!clientId || !clientSecret) {
    console.error('[youtube-oauth] preflight=runtime_configuration_incomplete');
    return res.status(503).send(page('YouTube runtime configuration incomplete', 'Client credentials are not configured.'));
  }

  const { code, state, error, error_description: errorDescription } = req.query || {};
  if (error) {
    console.error(`[youtube-oauth] preflight=authorization_not_completed error=${sanitizeError(errorDescription || error)}`);
    return res.status(400).send(page('YouTube authorization not completed', escapeHtml(errorDescription || error)));
  }
  if (!code || !state) {
    console.error(`[youtube-oauth] preflight=missing_oauth_response code_present=${Boolean(code)} state_present=${Boolean(state)}`);
    return res.status(400).send(page('Missing OAuth response', 'Authorization code or state is missing.'));
  }
  if (!validateSignedState(state, clientSecret)) {
    console.error('[youtube-oauth] preflight=invalid_or_expired_state');
    return res.status(400).send(page('Invalid or expired OAuth state', 'Start the YouTube authorization flow again.'));
  }

  let stage = 'exchange_code';
  try {
    const token = await exchangeCode({ code, clientId, clientSecret });
    const grantedScopes = String(token.scope || '').split(/\s+/).map((s) => s.trim()).filter(Boolean).sort();

    stage = 'verify_channel';
    const channel = await getMyChannel(token.access_token);
    if (!channel?.id) throw new Error('No YouTube channel was returned for the authorized Google account.');

    stage = 'create_encrypted_session';
    const encrypted = encryptSession({
      access_token: token.access_token,
      refresh_token: token.refresh_token || null,
      expires_at: Date.now() + Number(token.expires_in || 0) * 1000,
      scope: grantedScopes,
      channel_id: channel.id,
      channel_title: channel?.snippet?.title || null,
    }, clientSecret);

    res.setHeader('Set-Cookie', [
      `youtube_demo_session=${encrypted}; Path=/api/youtube; HttpOnly; Secure; SameSite=Lax; Max-Age=86400`,
    ]);

    const fingerprint = crypto.createHash('sha256').update(token.access_token).digest('hex').slice(0, 16);
    const receipt = {
      schema: 'nexo.youtube.oauth.connection.v1',
      status: 'connected_demo_session',
      channelId: channel.id,
      channelTitle: channel?.snippet?.title || null,
      scopes: grantedScopes,
      refreshTokenReceived: Boolean(token.refresh_token),
      tokenFingerprint: fingerprint,
      checkedAt: new Date().toISOString(),
    };

    console.info(`[youtube-oauth] status=${receipt.status} channel=${receipt.channelId} scopes=${grantedScopes.join(',')}`);
    return res.status(200).send(page(
      'YouTube OAuth connected',
      `<pre>${escapeHtml(JSON.stringify(receipt, null, 2))}</pre><p><a href="/api/youtube/demo">Continue to YouTube verification</a></p>`
    ));
  } catch (err) {
    console.error(`[youtube-oauth] stage=${stage} error=${sanitizeError(err?.message || err)}`);
    return res.status(502).send(page('YouTube OAuth verification failed', `${escapeHtml(stage)}: ${escapeHtml(sanitizeError(err?.message || 'Unknown error'))}`));
  }
}

async function exchangeCode({ code, clientId, clientSecret }) {
  const body = new URLSearchParams({
    code: String(code),
    client_id: clientId,
    client_secret: clientSecret,
    redirect_uri: REDIRECT_URI,
    grant_type: 'authorization_code',
  });
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Cache-Control': 'no-cache' },
    body,
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data.error || !data.access_token) {
    throw new Error(`Google token exchange: ${data.error_description || data.error || `HTTP ${response.status}`}`);
  }
  return data;
}

async function getMyChannel(accessToken) {
  const url = new URL('https://www.googleapis.com/youtube/v3/channels');
  url.searchParams.set('part', 'id,snippet');
  url.searchParams.set('mine', 'true');
  url.searchParams.set('maxResults', '1');
  const response = await fetch(url, {
    headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' },
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(`YouTube channel lookup: ${data?.error?.message || `HTTP ${response.status}`}`);
  }
  return data?.items?.[0] || null;
}

function validateSignedState(value, secret) {
  if (!value || typeof value !== 'string' || !value.includes('.')) return false;
  const [payload, signature] = value.split('.', 2);
  const expected = crypto
    .createHmac('sha256', `contentflow-youtube-state:${secret}`)
    .update(payload)
    .digest('base64url');
  try {
    const a = Buffer.from(signature, 'base64url');
    const b = Buffer.from(expected, 'base64url');
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return false;
    const parsed = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    const age = Date.now() - Number(parsed.iat);
    return Number.isFinite(Number(parsed.iat)) && age >= 0 && age <= 10 * 60 * 1000 && typeof parsed.nonce === 'string' && parsed.nonce.length >= 16;
  } catch {
    return false;
  }
}

function encryptSession(payload, secret) {
  const key = crypto.createHash('sha256').update(`contentflow-youtube-demo-v1:${secret}`).digest();
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(JSON.stringify(payload), 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();
  return [iv, tag, ciphertext].map((b) => b.toString('base64url')).join('.');
}

function sanitizeError(value) {
  return String(value)
    .replace(/(access_token|refresh_token|client_secret)=[^&\s]+/gi, '$1=[redacted]')
    .slice(0, 500);
}

function page(title, body) {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="robots" content="noindex,nofollow"><title>${escapeHtml(title)}</title></head><body><h1>${escapeHtml(title)}</h1><div>${body}</div><p>No Google or YouTube access/refresh token is displayed on this page.</p></body></html>`;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}
