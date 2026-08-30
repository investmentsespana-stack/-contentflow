import crypto from 'node:crypto';

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://koqpyfvnprmirqviafzq.supabase.co';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (req.method !== 'GET') return res.status(405).json({ status: 'method_not_allowed' });

  try {
    const connection = await loadConnection();
    if (!connection) return res.status(404).json({ schema: 'nexo.youtube.channel.v1', status: 'not_connected' });

    let accessToken = decryptVaultValue(connection, 'access_token');
    const refreshToken = connection.refresh_token_ciphertext ? decryptVaultValue(connection, 'refresh_token') : null;
    const expiresAt = connection.access_expires_at ? Date.parse(connection.access_expires_at) : 0;

    if (!accessToken || (refreshToken && (!expiresAt || Date.now() >= expiresAt - 60_000))) {
      if (!refreshToken) throw new Error('No usable YouTube access or refresh credential');
      accessToken = (await refreshAccessToken(refreshToken)).access_token;
    }

    let channel;
    try {
      channel = await getMyChannel(accessToken);
    } catch (err) {
      if (!refreshToken || !/401|invalid authentication|invalid credentials|unauthorized/i.test(String(err?.message || err))) throw err;
      accessToken = (await refreshAccessToken(refreshToken)).access_token;
      channel = await getMyChannel(accessToken);
    }

    if (!channel?.id || String(channel.id) !== String(connection.channel_id)) {
      return res.status(409).json({ schema: 'nexo.youtube.channel.v1', status: 'channel_mismatch' });
    }

    return res.status(200).json({
      schema: 'nexo.youtube.channel.v1',
      status: 'connected_operational',
      channel: {
        id: String(channel.id),
        title: channel?.snippet?.title || connection.channel_title || null,
        customUrl: channel?.snippet?.customUrl || null,
        publishedAt: channel?.snippet?.publishedAt || null,
        videoCount: channel?.statistics?.videoCount || null,
        subscriberCount: channel?.statistics?.subscriberCount || null,
        viewCount: channel?.statistics?.viewCount || null,
      },
      scopes: Array.isArray(connection.scopes) ? connection.scopes : [],
      refreshTokenAvailable: Boolean(refreshToken),
      checkedAt: new Date().toISOString(),
    });
  } catch (err) {
    console.error(`[youtube-channel] failed error=${sanitizeError(err?.message || err)}`);
    return res.status(502).json({ schema: 'nexo.youtube.channel.v1', status: 'error', error: sanitizeError(err?.message || err) });
  }
}

async function loadConnection() {
  const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRole) throw new Error('Supabase server credential missing');
  const url = `${SUPABASE_URL}/rest/v1/youtube_oauth_token_vault?select=channel_id,channel_title,scopes,access_token_ciphertext,access_token_iv,access_token_tag,refresh_token_ciphertext,refresh_token_iv,refresh_token_tag,access_expires_at&order=updated_at.desc&limit=1`;
  const response = await fetch(url, { headers: { apikey: serviceRole, Authorization: `Bearer ${serviceRole}`, Accept: 'application/json' } });
  if (!response.ok) throw new Error(`vault read HTTP ${response.status}`);
  const rows = await response.json();
  return Array.isArray(rows) ? rows[0] || null : null;
}

function decryptVaultValue(row, prefix) {
  const ciphertext = row[`${prefix}_ciphertext`];
  const iv = row[`${prefix}_iv`];
  const tag = row[`${prefix}_tag`];
  if (!ciphertext || !iv || !tag) return null;
  const material = process.env.YOUTUBE_TOKEN_ENCRYPTION_KEY || process.env.YOUTUBE_CLIENT_SECRET;
  if (!material) throw new Error('YouTube token encryption material missing');
  const key = crypto.createHash('sha256').update(`contentflow-youtube-token-v1:${material}`).digest();
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(iv, 'base64'));
  decipher.setAuthTag(Buffer.from(tag, 'base64'));
  return Buffer.concat([decipher.update(Buffer.from(ciphertext, 'base64')), decipher.final()]).toString('utf8');
}

async function refreshAccessToken(refreshToken) {
  const clientId = process.env.YOUTUBE_CLIENT_ID;
  const clientSecret = process.env.YOUTUBE_CLIENT_SECRET;
  if (!clientId || !clientSecret) throw new Error('YouTube OAuth runtime credentials incomplete');
  const response = await fetch('https://oauth2.googleapis.com/token', {
    method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' },
    body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret, refresh_token: refreshToken, grant_type: 'refresh_token' }),
  });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || !data?.access_token) throw new Error(`Google token refresh HTTP ${response.status}`);
  return data;
}

async function getMyChannel(accessToken) {
  const url = new URL('https://www.googleapis.com/youtube/v3/channels');
  url.searchParams.set('part', 'id,snippet,statistics');
  url.searchParams.set('mine', 'true');
  url.searchParams.set('maxResults', '1');
  const response = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' } });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`YouTube channel lookup HTTP ${response.status}: ${data?.error?.message || 'request failed'}`);
  return data?.items?.[0] || null;
}

function sanitizeError(value) {
  return String(value).replace(/ya29\.[A-Za-z0-9._-]+/g, '[redacted-token]').replace(/(access_token|refresh_token|client_secret)[=:][^&\s]+/gi, '$1=[redacted]').slice(0, 300);
}
