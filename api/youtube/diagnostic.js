export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method Not Allowed' });

  const clientId = process.env.YOUTUBE_CLIENT_ID || '';
  const clientSecret = process.env.YOUTUBE_CLIENT_SECRET || '';
  const redirectUri = process.env.YOUTUBE_OAUTH_REDIRECT_URI || 'https://investmentsespana.space/api/youtube/oauth/callback';

  return res.status(200).json({
    schema: 'nexo.youtube.runtime.preflight.v1',
    status: clientId && clientSecret ? 'ready' : 'incomplete',
    clientIdConfigured: Boolean(clientId),
    clientSecretConfigured: Boolean(clientSecret),
    clientIdLength: clientId.length,
    clientSecretLength: clientSecret.length,
    redirectUri,
    checkedAt: new Date().toISOString(),
  });
}
