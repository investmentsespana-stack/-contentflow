import crypto from 'node:crypto';
import { buildYouTubeManagementPreflight } from '../../src/platform/youtube-management-preflight.mjs';

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://koqpyfvnprmirqviafzq.supabase.co';
const TARGET_CHANNEL_ID = 'UCZhxLanR9eh7u2PtMv9Bxjg';
const TARGET_TITLE = 'Cygnus Academy AI';
const TARGET_DESCRIPTION = 'Cygnus Academy AI explora y demuestra aplicaciones reales de inteligencia artificial, automatización y sistemas multiagente. Aprendemos haciendo: el humano define propósito, reglas y criterio; la IA ayuda a investigar, ejecutar y verificar.\n\nAprendiendo Haciendo – Formación para el trabajo.';
const BANNER_URL = 'https://raw.githubusercontent.com/investmentsespana-stack/-contentflow/main/academy/social/youtube/branding/cygnus_youtube_banner_2560x1440.jpg';
const WATERMARK_URL = 'https://raw.githubusercontent.com/investmentsespana-stack/-contentflow/main/academy/social/youtube/branding/cygnus_youtube_watermark_150x150.png';
const PLAYLISTS = [
  ['Empieza aquí', 'Contenido introductorio y orientación para comenzar en Cygnus Academy AI.'],
  ['Shorts | IA aplicada', 'Ideas breves y prácticas sobre inteligencia artificial aplicada al trabajo.'],
  ['IA aplicada al trabajo', 'Casos, marcos y prácticas para aplicar IA a procesos reales de trabajo.'],
  ['Automatización y agentes', 'Automatización, agentes y sistemas multiagente aplicados.'],
  ['Auditoría 360', 'Análisis integral antes de automatizar: procesos, datos, riesgos, costos y retorno.'],
  ['Clases y cursos', 'Clases y cursos de Cygnus Academy AI.'],
  ['Profesores y avatares', 'Contenido docente y perfiles de profesores y avatares aprobados.'],
];

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (req.method !== 'GET') return res.status(405).json({ error: 'Method Not Allowed' });

  const action = String(req.query?.action || '');
  if (action === 'management-preflight') return managementPreflight(res);
  if (action === 'execute-institutionalization') return executeInstitutionalization(res);

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
  if (!serviceRole) return res.status(503).json({ schema: 'nexo.youtube.management.preflight.v1', status: 'runtime_configuration_incomplete', secretsExposed: false });
  try {
    const vault = await getVaultMetadata(serviceRole);
    if (!vault?.channel_id) throw new Error('YouTube token vault is empty');
    const receipt = buildYouTubeManagementPreflight({ channelId: vault.channel_id, scopes: Array.isArray(vault.scopes) ? vault.scopes : [] });
    return res.status(200).json({ ...receipt, source: 'persisted_vault_metadata', vaultUpdatedAt: vault.updated_at || null, secretsExposed: false });
  } catch (error) {
    return res.status(502).json({ schema: 'nexo.youtube.management.preflight.v1', status: 'failed', error: sanitizeError(error), secretsExposed: false });
  }
}

async function executeInstitutionalization(res) {
  const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const clientId = process.env.YOUTUBE_CLIENT_ID;
  const clientSecret = process.env.YOUTUBE_CLIENT_SECRET;
  if (!serviceRole || !clientId || !clientSecret) return res.status(503).json({ schema: 'nexo.youtube.institutionalization.receipt.v1', status: 'runtime_configuration_incomplete', secretsExposed: false });

  const steps = [];
  try {
    const vault = await getVaultSecrets(serviceRole);
    if (!vault?.channel_id || String(vault.channel_id) !== TARGET_CHANNEL_ID) throw new Error('Persisted channel does not match approved target');
    if (!Array.isArray(vault.scopes) || !vault.scopes.includes('https://www.googleapis.com/auth/youtube')) throw new Error('Persisted OAuth scopes do not include YouTube management');

    const key = deriveEncryptionKey(clientSecret);
    let accessToken = decryptValue(vault.access_token_ciphertext, vault.access_token_iv, vault.access_token_tag, key);
    const refreshToken = vault.refresh_token_ciphertext ? decryptValue(vault.refresh_token_ciphertext, vault.refresh_token_iv, vault.refresh_token_tag, key) : null;
    if (!vault.access_expires_at || Date.now() >= Date.parse(vault.access_expires_at) - 60_000) {
      if (!refreshToken) throw new Error('Persisted access token expired and refresh token is unavailable');
      accessToken = (await refreshAccessToken({ refreshToken, clientId, clientSecret })).access_token;
    }

    const before = await getChannel(accessToken);
    if (!before?.id || String(before.id) !== TARGET_CHANNEL_ID) throw new Error('Live channel verification mismatch');
    steps.push({ item: 'channel_verification', status: 'DONE', channelId: before.id, titleBefore: before?.snippet?.title || null });

    let bannerExternalUrl = null;
    try {
      const bannerBytes = await fetchAsset(BANNER_URL, 'image/jpeg');
      const upload = await googleMediaUpload(`https://www.googleapis.com/upload/youtube/v3/channelBanners/insert?channelId=${encodeURIComponent(TARGET_CHANNEL_ID)}&uploadType=media`, accessToken, bannerBytes, 'image/jpeg');
      bannerExternalUrl = upload?.url || null;
      if (!bannerExternalUrl) throw new Error('YouTube banner upload did not return a URL');
      steps.push({ item: 'banner_upload', status: 'DONE' });
    } catch (error) {
      steps.push({ item: 'banner_upload', status: 'BLOCKED', error: sanitizeError(error) });
    }

    try {
      const current = before.brandingSettings || {};
      const brandingSettings = {
        ...current,
        channel: {
          ...(current.channel || {}),
          title: TARGET_TITLE,
          description: TARGET_DESCRIPTION,
        },
      };
      if (bannerExternalUrl) brandingSettings.image = { ...(current.image || {}), bannerExternalUrl };
      const response = await fetch('https://www.googleapis.com/youtube/v3/channels?part=brandingSettings', {
        method: 'PUT',
        headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json', Accept: 'application/json' },
        body: JSON.stringify({ id: TARGET_CHANNEL_ID, brandingSettings }),
      });
      const data = await response.json().catch(() => ({}));
      if (!response.ok) throw new Error(`channels.update HTTP ${response.status}: ${data?.error?.message || 'unknown'}`);
      steps.push({ item: 'public_name_description_banner', status: 'DONE', title: data?.brandingSettings?.channel?.title || TARGET_TITLE, descriptionApplied: true, bannerApplied: Boolean(bannerExternalUrl) });
    } catch (error) {
      steps.push({ item: 'public_name_description_banner', status: 'BLOCKED', error: sanitizeError(error) });
    }

    try {
      const watermarkBytes = await fetchAsset(WATERMARK_URL, 'image/png');
      const boundary = `cygnus_${crypto.randomBytes(12).toString('hex')}`;
      const metadata = JSON.stringify({ timing: { type: 'offsetFromStart', offsetMs: '0', durationMs: '600000000' }, position: { type: 'corner', cornerPosition: 'bottomRight' }, targetChannelId: TARGET_CHANNEL_ID });
      const head = Buffer.from(`--${boundary}\r\nContent-Type: application/json; charset=UTF-8\r\n\r\n${metadata}\r\n--${boundary}\r\nContent-Type: image/png\r\n\r\n`);
      const tail = Buffer.from(`\r\n--${boundary}--\r\n`);
      const body = Buffer.concat([head, watermarkBytes, tail]);
      const response = await fetch(`https://www.googleapis.com/upload/youtube/v3/watermarks/set?channelId=${encodeURIComponent(TARGET_CHANNEL_ID)}&uploadType=multipart`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': `multipart/related; boundary=${boundary}`, 'Content-Length': String(body.length) },
        body,
      });
      if (!response.ok) {
        const data = await response.json().catch(() => ({}));
        throw new Error(`watermarks.set HTTP ${response.status}: ${data?.error?.message || 'unknown'}`);
      }
      steps.push({ item: 'watermark', status: 'DONE' });
    } catch (error) {
      steps.push({ item: 'watermark', status: 'BLOCKED', error: sanitizeError(error) });
    }

    const existingPlaylists = await listPlaylists(accessToken);
    const existingByTitle = new Map(existingPlaylists.map((p) => [String(p?.snippet?.title || '').trim(), p]));
    const playlistResults = [];
    for (const [title, description] of PLAYLISTS) {
      if (existingByTitle.has(title)) {
        playlistResults.push({ title, status: 'DONE', action: 'already_exists', id: existingByTitle.get(title)?.id || null });
        continue;
      }
      try {
        const response = await fetch('https://www.googleapis.com/youtube/v3/playlists?part=snippet,status', {
          method: 'POST',
          headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': 'application/json', Accept: 'application/json' },
          body: JSON.stringify({ snippet: { title, description }, status: { privacyStatus: 'private' } }),
        });
        const data = await response.json().catch(() => ({}));
        if (!response.ok) throw new Error(`playlists.insert HTTP ${response.status}: ${data?.error?.message || 'unknown'}`);
        playlistResults.push({ title, status: 'DONE', action: 'created_private', id: data?.id || null });
      } catch (error) {
        playlistResults.push({ title, status: 'BLOCKED', error: sanitizeError(error) });
      }
    }
    steps.push({ item: 'playlists', status: playlistResults.every((x) => x.status === 'DONE') ? 'DONE' : 'PARTIAL', results: playlistResults });

    steps.push({ item: 'avatar', status: 'BLOCKED', gate: 'authenticated_studio_required', reason: 'YouTube Data API has no certified avatar write method in this adapter.' });
    steps.push({ item: 'institutional_links', status: 'BLOCKED', gate: 'authenticated_studio_required', reason: 'Profile links are not exposed by the certified YouTube Data API adapter; only verified URLs may be entered in Studio.' });
    steps.push({ item: 'handle', status: 'BLOCKED', gate: 'authenticated_studio_required', preferred: '@CygnusAcademyAI', fallback: '@CygnusAcademyIA', reason: 'Handle availability must be confirmed at the real Studio save gate.' });
    steps.push({ item: 'home_sections', status: 'PARTIAL', reason: 'Private empty playlists were prepared without publishing videos or exposing empty public sections.' });

    const after = await getChannel(accessToken);
    const afterPlaylists = await listPlaylists(accessToken);
    const overall = steps.some((x) => x.status === 'BLOCKED') ? 'PARTIAL' : 'DONE';
    return res.status(200).json({
      schema: 'nexo.youtube.institutionalization.receipt.v1',
      status: overall,
      channelId: after?.id || null,
      before: { title: before?.snippet?.title || null, description: before?.snippet?.description || '', customUrl: before?.snippet?.customUrl || null },
      after: { title: after?.snippet?.title || null, description: after?.snippet?.description || '', customUrl: after?.snippet?.customUrl || null, playlistCount: afterPlaylists.length },
      steps,
      noVideoUpload: true,
      noPublicPublish: true,
      noPermanentDelete: true,
      secretsExposed: false,
      checkedAt: new Date().toISOString(),
    });
  } catch (error) {
    return res.status(502).json({ schema: 'nexo.youtube.institutionalization.receipt.v1', status: 'failed', error: sanitizeError(error), steps, secretsExposed: false, checkedAt: new Date().toISOString() });
  }
}

async function getVaultMetadata(serviceRole) {
  const fields = ['channel_id', 'scopes', 'updated_at'].join(',');
  const url = `${SUPABASE_URL}/rest/v1/youtube_oauth_token_vault?select=${encodeURIComponent(fields)}&order=updated_at.desc&limit=1`;
  return (await supabaseRows(url, serviceRole))?.[0] || null;
}

async function getVaultSecrets(serviceRole) {
  const fields = ['channel_id','scopes','access_token_ciphertext','access_token_iv','access_token_tag','refresh_token_ciphertext','refresh_token_iv','refresh_token_tag','access_expires_at','updated_at'].join(',');
  const url = `${SUPABASE_URL}/rest/v1/youtube_oauth_token_vault?select=${encodeURIComponent(fields)}&order=updated_at.desc&limit=1`;
  return (await supabaseRows(url, serviceRole))?.[0] || null;
}

async function supabaseRows(url, serviceRole) {
  const response = await fetch(url, { headers: { apikey: serviceRole, Authorization: `Bearer ${serviceRole}`, Accept: 'application/json' } });
  const rows = await response.json().catch(() => []);
  if (!response.ok) throw new Error(`vault lookup HTTP ${response.status}`);
  return rows;
}

async function getChannel(accessToken) {
  const url = new URL('https://www.googleapis.com/youtube/v3/channels');
  url.searchParams.set('part', 'id,snippet,brandingSettings,contentDetails,statistics,status');
  url.searchParams.set('mine', 'true');
  url.searchParams.set('maxResults', '1');
  const response = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' } });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`channels.list HTTP ${response.status}: ${data?.error?.message || 'unknown'}`);
  return data?.items?.[0] || null;
}

async function listPlaylists(accessToken) {
  const items = [];
  let pageToken = null;
  do {
    const url = new URL('https://www.googleapis.com/youtube/v3/playlists');
    url.searchParams.set('part', 'id,snippet,status,contentDetails');
    url.searchParams.set('mine', 'true');
    url.searchParams.set('maxResults', '50');
    if (pageToken) url.searchParams.set('pageToken', pageToken);
    const response = await fetch(url, { headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' } });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(`playlists.list HTTP ${response.status}: ${data?.error?.message || 'unknown'}`);
    items.push(...(Array.isArray(data.items) ? data.items : []));
    pageToken = data.nextPageToken || null;
  } while (pageToken);
  return items;
}

async function fetchAsset(url, expectedType) {
  const response = await fetch(url);
  if (!response.ok) throw new Error(`asset fetch HTTP ${response.status}`);
  const type = response.headers.get('content-type') || '';
  if (expectedType && !type.includes(expectedType.split('/')[1])) throw new Error(`asset content-type mismatch: ${type}`);
  return Buffer.from(await response.arrayBuffer());
}

async function googleMediaUpload(url, accessToken, bytes, contentType) {
  const response = await fetch(url, { method: 'POST', headers: { Authorization: `Bearer ${accessToken}`, 'Content-Type': contentType, 'Content-Length': String(bytes.length), Accept: 'application/json' }, body: bytes });
  const data = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error(`media upload HTTP ${response.status}: ${data?.error?.message || 'unknown'}`);
  return data;
}

async function refreshAccessToken({ refreshToken, clientId, clientSecret }) {
  const response = await fetch('https://oauth2.googleapis.com/token', { method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded', Accept: 'application/json' }, body: new URLSearchParams({ client_id: clientId, client_secret: clientSecret, refresh_token: refreshToken, grant_type: 'refresh_token' }) });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || !data?.access_token) throw new Error(`Google token refresh: ${data?.error_description || data?.error || `HTTP ${response.status}`}`);
  return data;
}

function deriveEncryptionKey(clientSecret) {
  const material = process.env.YOUTUBE_TOKEN_ENCRYPTION_KEY || clientSecret;
  return crypto.createHash('sha256').update(`contentflow-youtube-token-v1:${material}`).digest();
}

function decryptValue(ciphertext, iv, tag, key) {
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(iv, 'base64'));
  decipher.setAuthTag(Buffer.from(tag, 'base64'));
  return Buffer.concat([decipher.update(Buffer.from(ciphertext, 'base64')), decipher.final()]).toString('utf8');
}

function sanitizeError(error) {
  return String(error?.message || error).replace(/(access_token|refresh_token|client_secret)=[^&\s]+/gi, '$1=[redacted]').replace(/ya29\.[A-Za-z0-9._-]+/g, '[redacted-token]').slice(0, 500);
}
