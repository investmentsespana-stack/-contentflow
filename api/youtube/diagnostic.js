import { buildYouTubeManagementPreflight } from '../../src/platform/youtube-management-preflight.mjs';

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://koqpyfvnprmirqviafzq.supabase.co';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method Not Allowed' });

  if (String(req.query?.action || '') === 'management-preflight') {
    return managementPreflight(res);
  }

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

async function managementPreflight(res) {
  const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRole) {
    return res.status(503).json({
      schema: 'nexo.youtube.management.preflight.v1',
      status: 'runtime_configuration_incomplete',
      secretsExposed: false,
    });
  }

  try {
    const fields = ['channel_id', 'scopes', 'updated_at'].join(',');
    const url = `${SUPABASE_URL}/rest/v1/youtube_oauth_token_vault?select=${encodeURIComponent(fields)}&order=updated_at.desc&limit=1`;
    const response = await fetch(url, {
      headers: {
        apikey: serviceRole,
        Authorization: `Bearer ${serviceRole}`,
        Accept: 'application/json',
      },
    });
    const rows = await response.json().catch(() => []);
    if (!response.ok) throw new Error(`vault lookup HTTP ${response.status}`);
    const vault = rows?.[0] || null;
    if (!vault?.channel_id) throw new Error('YouTube token vault is empty');

    const receipt = buildYouTubeManagementPreflight({
      channelId: vault.channel_id,
      scopes: Array.isArray(vault.scopes) ? vault.scopes : [],
    });

    return res.status(200).json({
      ...receipt,
      source: 'persisted_vault_metadata',
      vaultUpdatedAt: vault.updated_at || null,
      secretsExposed: false,
    });
  } catch (error) {
    return res.status(502).json({
      schema: 'nexo.youtube.management.preflight.v1',
      status: 'failed',
      error: String(error?.message || error).slice(0, 300),
      secretsExposed: false,
    });
  }
}
