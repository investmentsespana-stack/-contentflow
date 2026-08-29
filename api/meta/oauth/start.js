import crypto from 'node:crypto';

const APP_ID = process.env.META_APP_ID || '1784797469372306';
const REDIRECT_URI = process.env.META_OAUTH_REDIRECT_URI || 'https://contentflow-ai-tan.vercel.app/api/meta/oauth/callback';
const GRAPH_VERSION = process.env.META_GRAPH_VERSION || 'v23.0';
const SCOPES = [
  'public_profile',
  'pages_show_list',
  'pages_read_engagement',
  'pages_manage_posts',
  'instagram_basic',
  'instagram_content_publish',
];

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  if (req.method !== 'GET') return res.status(405).send('Method Not Allowed');

  const appSecret = process.env.META_APP_SECRET;
  if (!appSecret) return res.status(503).send('META_APP_SECRET is not configured.');

  const payload = Buffer.from(JSON.stringify({
    iat: Date.now(),
    nonce: crypto.randomBytes(18).toString('base64url'),
  })).toString('base64url');
  const signature = signState(payload, appSecret);
  const state = `${payload}.${signature}`;

  const url = new URL(`https://www.facebook.com/${GRAPH_VERSION}/dialog/oauth`);
  url.searchParams.set('client_id', APP_ID);
  url.searchParams.set('redirect_uri', REDIRECT_URI);
  url.searchParams.set('state', state);
  url.searchParams.set('response_type', 'code');
  url.searchParams.set('scope', SCOPES.join(','));
  url.searchParams.set('auth_type', 'rerequest');

  return res.redirect(302, url.toString());
}

function signState(payload, appSecret) {
  return crypto.createHmac('sha256', `contentflow-meta-state:${appSecret}`)
    .update(payload)
    .digest('base64url');
}
