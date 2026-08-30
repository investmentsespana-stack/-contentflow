import crypto from 'node:crypto';
import inventoryHandler from '../../src/platform/youtube-channel-inventory.mjs';

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://koqpyfvnprmirqviafzq.supabase.co';

export default async function handler(req, res) {
  if (req.method === 'POST' && String(req.query?.action || '') === 'inventory') {
    return inventoryHandler(req, res);
  }
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  if (req.method !== 'GET') return res.status(405).send('Method Not Allowed');

  const secret = process.env.YOUTUBE_CLIENT_SECRET;
  if (!secret) return res.status(503).send(page('YouTube demo unavailable', '<p>Runtime credential is not configured.</p>'));

  const cookie = parseCookies(req.headers.cookie || '').youtube_demo_session;
  if (!cookie) {
    return res.status(200).send(page(
      'Cygnus Academy AI · YouTube',
      '<p>No authorized YouTube session is active.</p><p><a href="/api/youtube/oauth/start">Connect YouTube</a></p>'
    ));
  }

  try {
    const session = decryptSession(cookie, secret);
    if (String(req.query?.persist || '') === '1') {
      return persistVerifiedSession({ session, secret, res });
    }

    const expired = !session.expires_at || Date.now() >= Number(session.expires_at);
    const receipt = {
      schema: 'nexo.youtube.demo.session.v2',
      status: expired ? 'access_token_expired' : 'connected',
      channelId: session.channel_id || null,
      channelTitle: session.channel_title || null,
      scopes: Array.isArray(session.scope) ? session.scope : [],
      refreshTokenAvailable: Boolean(session.refresh_token),
      checkedAt: new Date().toISOString(),
    };
    return res.status(200).send(page(
      'Cygnus Academy AI · YouTube connected',
      `<pre>${escapeHtml(JSON.stringify(receipt, null, 2))}</pre><p><a href="/api/youtube/demo?persist=1">Persist verified connection securely</a></p>`
    ));
  } catch {
    return res.status(400).send(page('YouTube session invalid', '<p><a href="/api/youtube/oauth/start">Start a new authorization</a></p>'));
  }
}

async function persistVerifiedSession({ session, secret, res }) {
  const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRole) return res.status(503).send(page('YouTube persistence configuration incomplete', '<p>Server-side vault credentials are missing.</p>'));
  if (!session?.access_token || !session?.channel_id) return res.status(400).send(page('YouTube verified session incomplete', '<p>No token was persisted.</p>'));

  try {
    let accessToken = session.access_token;
    let accessExpiresAt = session.expires_at ? Number(session.expires_at) : null;

    const shouldRefresh = Boolean(session.refresh_token) && (!accessExpiresAt || Date.now() >= accessExpiresAt - 60_000);
    if (shouldRefresh) {
      const refreshed = await refreshAccessToken(session.refresh_token);
      accessToken = refreshed.access_token;
      accessExpiresAt = Date.now() + Number(refreshed.expires_in || 3600) * 1000;
    }

    let channel;
    try {
      channel = await getMyChannel(accessToken);
    } catch (err) {
      const authFailure = /invalid authentication credentials|invalid credentials|unauthorized|401/i.test(String(err?.message || err));
      if (!authFailure || !session.refresh_token) throw err;
      const refreshed = await refreshAccessToken(session.refresh_token);
      accessToken = refreshed.access_token;
      accessExpiresAt = Date.now() + Number(refreshed.expires_in || 3600) * 1000;
      channel = await getMyChannel(accessToken);
    }

    if (!channel?.id || String(channel.id) !== String(session.channel_id)) {
      return res.status(403).send(page('YouTube channel verification mismatch', '<p>No token was persisted.</p>'));
    }

    const fingerprint = crypto.createHash('sha256').update(accessToken).digest('hex').slice(0, 16);
    const key = deriveEncryptionKey(secret);
    const access = encryptValue(accessToken, key);
    const refresh = session.refresh_token ? encryptValue(session.refresh_token, key) : null;

    const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/upsert_youtube_oauth_token`, {
      method: 'POST',
      headers: {
        apikey: serviceRole,
        Authorization: `Bearer ${serviceRole}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        p_channel_id: String(channel.id),
        p_channel_title: channel?.snippet?.title || session.channel_title || null,
        p_scopes: Array.isArray(session.scope) ? session.scope : [],
        p_access_token_ciphertext: access.ciphertext,
        p_access_token_iv: access.iv,
        p_access_token_tag: access.tag,
        p_refresh_token_ciphertext: refresh?.ciphertext || null,
        p_refresh_token_iv: refresh?.iv || null,
        p_refresh_token_tag: refresh?.tag || null,
        p_token_fingerprint: fingerprint,
        p_access_expires_at: accessExpiresAt ? new Date(accessExpiresAt).toISOString() : null,
        p_refresh_token_received: Boolean(session.refresh_token),
      }),
    });
    if (!response.ok) throw new Error(`vault HTTP ${response.status}`);

    const receipt = {
      schema: 'nexo.youtube.oauth.persistence.v1',
      status: 'connected_persisted',
      channelId: String(channel.id),
      channelTitle: channel?.snippet?.title || null,
      scopes: Array.isArray(session.scope) ? session.scope : [],
      refreshTokenPersisted: Boolean(session.refresh_token),
      tokenFingerprint: fingerprint,
      checkedAt: new Date().toISOString(),
    };
    console.info(`[youtube-oauth] persistence_bridge=success channel=${receipt.channelId} refresh=${receipt.refreshTokenPersisted}`);
    return res.status(200).send(page('YouTube OAuth persisted', `<pre>${escapeHtml(JSON.stringify(receipt, null, 2))}</pre>`));
  } catch (err) {
    console.error(`[youtube-oauth] persistence_bridge=failed error=${sanitizeError(err?.message || err)}`);
    return res.status(502).send(page('YouTube persistence failed', `<p>${escapeHtml(sanitizeError(err?.message || 'Unknown error'))}</p>`));
  }
}

async function refreshAccessToken(refreshToken) {
  const clientId = process.env.YOUTUBE_CLIENT_ID;
  const clientSecret = process.env.YOUTUBE_CLIENT_SECRET;
  if (!clientId || !clientSecret) throw new Error('YouTube OAuth runtime credentials are incomplete');

  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST',
    headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
    body: new URLSearchParams({
      client_id: clientId,
      client_secret: clientSecret,
      refresh_token: refreshToken,
      grant_type: 'refresh_token',
    }),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || !data?.access_token) {
    throw new Error(`Google token refresh: ${data?.error_description || data?.error || `HTTP ${response.status}`}`);
  }
  return data;
}

async function getMyChannel(accessToken) {
  const url = new URL('https://www.googleapis.com/youtube/v3/channels');
  url.searchParams.set('part', 'id,snippet');
  url.searchParams.set('mine', 'true');
  url.searchParams.set('maxResults', '1');
  const response = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' } });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`YouTube channel lookup: ${data?.error?.message || `HTTP ${response.status}`}`);
  return data?.items?.[0] || null;
}

function decryptSession(value, secret) {
  const [ivPart, tagPart, ciphertextPart] = String(value).split('.');
  if (!ivPart || !tagPart || !ciphertextPart) throw new Error('Malformed session');
  const key = crypto.createHash('sha256').update(`contentflow-youtube-demo-v1:${secret}`).digest();
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(ivPart, 'base64url'));
  decipher.setAuthTag(Buffer.from(tagPart, 'base64url'));
  const plaintext = Buffer.concat([decipher.update(Buffer.from(ciphertextPart, 'base64url')), decipher.final()]).toString('utf8');
  return JSON.parse(plaintext);
}

function deriveEncryptionKey(secret) {
  const material = process.env.YOUTUBE_TOKEN_ENCRYPTION_KEY || secret;
  return crypto.createHash('sha256').update(`contentflow-youtube-token-v1:${material}`).digest();
}

function encryptValue(value, key) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(String(value), 'utf8'), cipher.final()]);
  return { ciphertext: ciphertext.toString('base64'), iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64') };
}

function parseCookies(header) {
  return header.split(';').reduce((acc, pair) => {
    const index = pair.indexOf('=');
    if (index < 0) return acc;
    const key = pair.slice(0, index).trim();
    const value = pair.slice(index + 1).trim();
    if (key) acc[key] = value;
    return acc;
  }, {});
}

function sanitizeError(value) {
  return String(value).replace(/(access_token|refresh_token|client_secret)=[^&\s]+/gi, '$1=[redacted]').replace(/ya29\.[A-Za-z0-9._-]+/g, '[redacted-token]').slice(0, 500);
}

function page(title, body) {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="robots" content="noindex,nofollow"><title>${escapeHtml(title)}</title></head><body><h1>${escapeHtml(title)}</h1>${body}<p>No Google or YouTube access/refresh token is displayed on this page.</p></body></html>`;
}

function escapeHtml(value) {
  return String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#039;');
}
