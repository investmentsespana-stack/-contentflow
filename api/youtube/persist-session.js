import crypto from 'node:crypto';

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://koqpyfvnprmirqviafzq.supabase.co';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  if (req.method !== 'GET') return res.status(405).send('Method Not Allowed');

  const clientSecret = process.env.YOUTUBE_CLIENT_SECRET;
  const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!clientSecret || !serviceRole) {
    return res.status(503).send(page('YouTube persistence configuration incomplete', 'Required server-side configuration is missing.'));
  }

  const cookie = parseCookie(req.headers.cookie || '').youtube_demo_session;
  if (!cookie) return res.status(401).send(page('No verified YouTube session found', 'Run the YouTube OAuth verification flow first in this browser.'));

  let session;
  try {
    session = decryptSession(cookie, clientSecret);
  } catch {
    return res.status(401).send(page('Verified YouTube session is invalid', 'Run the YouTube OAuth verification flow again.'));
  }

  if (!session?.access_token || !session?.channel_id) {
    return res.status(400).send(page('Verified YouTube session is incomplete', 'Required channel or token data is missing.'));
  }

  try {
    const channel = await getMyChannel(session.access_token);
    if (!channel?.id || String(channel.id) !== String(session.channel_id)) {
      return res.status(403).send(page('YouTube channel verification mismatch', 'No token was persisted.'));
    }

    const fingerprint = crypto.createHash('sha256').update(session.access_token).digest('hex').slice(0, 16);
    const key = deriveEncryptionKey(clientSecret);
    const access = encryptValue(session.access_token, key);
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
        p_access_expires_at: session.expires_at ? new Date(Number(session.expires_at)).toISOString() : null,
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
    return res.status(502).send(page('YouTube persistence failed', escapeHtml(sanitizeError(err?.message || 'Unknown error'))));
  }
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
  const [ivRaw, tagRaw, ciphertextRaw] = String(value).split('.', 3);
  if (!ivRaw || !tagRaw || !ciphertextRaw) throw new Error('invalid session');
  const key = crypto.createHash('sha256').update(`contentflow-youtube-demo-v1:${secret}`).digest();
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(ivRaw, 'base64url'));
  decipher.setAuthTag(Buffer.from(tagRaw, 'base64url'));
  const plaintext = Buffer.concat([decipher.update(Buffer.from(ciphertextRaw, 'base64url')), decipher.final()]).toString('utf8');
  return JSON.parse(plaintext);
}

function deriveEncryptionKey(clientSecret) {
  const material = process.env.YOUTUBE_TOKEN_ENCRYPTION_KEY || clientSecret;
  return crypto.createHash('sha256').update(`contentflow-youtube-token-v1:${material}`).digest();
}

function encryptValue(value, key) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(String(value), 'utf8'), cipher.final()]);
  return { ciphertext: ciphertext.toString('base64'), iv: iv.toString('base64'), tag: cipher.getAuthTag().toString('base64') };
}

function parseCookie(header) {
  return String(header).split(';').map((x) => x.trim()).filter(Boolean).reduce((acc, item) => {
    const i = item.indexOf('=');
    if (i > 0) acc[item.slice(0, i)] = item.slice(i + 1);
    return acc;
  }, {});
}

function sanitizeError(value) {
  return String(value).replace(/(access_token|refresh_token|client_secret)=[^&\s]+/gi, '$1=[redacted]').replace(/ya29\.[A-Za-z0-9._-]+/g, '[redacted-token]').slice(0, 500);
}

function page(title, body) {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="robots" content="noindex,nofollow"><title>${escapeHtml(title)}</title></head><body><h1>${escapeHtml(title)}</h1><div>${body}</div><p>No Google or YouTube access/refresh token is displayed on this page.</p></body></html>`;
}

function escapeHtml(value) {
  return String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('>', '&gt;').replaceAll('"', '&quot;').replaceAll("'", '&#039;');
}
