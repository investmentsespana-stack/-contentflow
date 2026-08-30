import crypto from 'node:crypto';

const REDIRECT_URI = process.env.TIKTOK_OAUTH_REDIRECT_URI || 'https://investmentsespana.space/api/tiktok/oauth/callback';
const SCOPES = ['user.info.basic', 'video.upload'];

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'GET') return res.status(405).send('Method Not Allowed');

  const { clientKey, clientSecret, mode } = getCredentials();
  if (!clientKey || !clientSecret) {
    return res.status(503).send(`TikTok ${mode} runtime credentials are not configured.`);
  }

  const payload = Buffer.from(JSON.stringify({
    iat: Date.now(),
    nonce: crypto.randomBytes(24).toString('base64url'),
    mode,
  })).toString('base64url');
  const signature = crypto
    .createHmac('sha256', `contentflow-tiktok-state:${clientSecret}`)
    .update(payload)
    .digest('base64url');
  const state = `${payload}.${signature}`;

  const url = new URL('https://www.tiktok.com/v2/auth/authorize/');
  url.searchParams.set('client_key', clientKey);
  url.searchParams.set('scope', SCOPES.join(','));
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('redirect_uri', REDIRECT_URI);
  url.searchParams.set('state', state);

  return res.redirect(302, url.toString());
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
