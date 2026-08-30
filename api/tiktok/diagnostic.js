export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method Not Allowed' });

  const requestedMode = String(process.env.TIKTOK_OAUTH_MODE || 'production').toLowerCase();
  const mode = requestedMode === 'sandbox' ? 'sandbox' : 'production';
  const clientKey = mode === 'sandbox' ? process.env.TIKTOK_SANDBOX_CLIENT_KEY : process.env.TIKTOK_CLIENT_KEY;
  const clientSecret = mode === 'sandbox' ? process.env.TIKTOK_SANDBOX_CLIENT_SECRET : process.env.TIKTOK_CLIENT_SECRET;

  return res.status(200).json({
    schema: 'nexo.tiktok.runtime.preflight.v2',
    status: clientKey && clientSecret ? 'ready' : 'incomplete',
    mode,
    clientKeyConfigured: Boolean(clientKey),
    clientSecretConfigured: Boolean(clientSecret),
    clientKeyLength: String(clientKey || '').length,
    clientSecretLength: String(clientSecret || '').length,
    redirectUri: process.env.TIKTOK_OAUTH_REDIRECT_URI || 'https://investmentsespana.space/api/tiktok/oauth/callback',
    scopes: ['user.info.basic', 'video.upload'],
    checkedAt: new Date().toISOString(),
  });
}
