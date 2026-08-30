import crypto from 'node:crypto';

export default async function handler(req, res) {
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
    const expired = !session.expires_at || Date.now() >= Number(session.expires_at);
    const receipt = {
      schema: 'nexo.youtube.demo.session.v1',
      status: expired ? 'access_token_expired' : 'connected',
      channelId: session.channel_id || null,
      channelTitle: session.channel_title || null,
      scopes: Array.isArray(session.scope) ? session.scope : [],
      refreshTokenAvailable: Boolean(session.refresh_token),
      checkedAt: new Date().toISOString(),
    };
    return res.status(200).send(page(
      'Cygnus Academy AI · YouTube connected',
      `<pre>${escapeHtml(JSON.stringify(receipt, null, 2))}</pre><p>Upload and channel-management actions remain disabled until the authorized channel identity is reviewed.</p>`
    ));
  } catch {
    return res.status(400).send(page('YouTube session invalid', '<p><a href="/api/youtube/oauth/start">Start a new authorization</a></p>'));
  }
}

function decryptSession(value, secret) {
  const [ivPart, tagPart, ciphertextPart] = String(value).split('.');
  if (!ivPart || !tagPart || !ciphertextPart) throw new Error('Malformed session');
  const key = crypto.createHash('sha256').update(`contentflow-youtube-demo-v1:${secret}`).digest();
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(ivPart, 'base64url'));
  decipher.setAuthTag(Buffer.from(tagPart, 'base64url'));
  const plaintext = Buffer.concat([
    decipher.update(Buffer.from(ciphertextPart, 'base64url')),
    decipher.final(),
  ]).toString('utf8');
  return JSON.parse(plaintext);
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

function page(title, body) {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="robots" content="noindex,nofollow"><title>${escapeHtml(title)}</title></head><body><h1>${escapeHtml(title)}</h1>${body}<p>No Google or YouTube access/refresh token is displayed on this page.</p></body></html>`;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}
