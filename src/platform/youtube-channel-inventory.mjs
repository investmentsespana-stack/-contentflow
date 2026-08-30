import crypto from 'node:crypto';

const SUPABASE_URL = process.env.SUPABASE_URL || 'https://koqpyfvnprmirqviafzq.supabase.co';
const PROJECT_KEY = 'skool_proyecto_academia';
const TASK_KEY = 'youtube_channel_inventory_v1';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (!['GET', 'POST'].includes(req.method)) return res.status(405).json({ error: 'Method Not Allowed' });

  const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const clientId = process.env.YOUTUBE_CLIENT_ID;
  const clientSecret = process.env.YOUTUBE_CLIENT_SECRET;
  if (!serviceRole || !clientId || !clientSecret) {
    return res.status(503).json({
      schema: 'nexo.youtube.inventory.receipt.v1',
      status: 'runtime_configuration_incomplete',
    });
  }

  try {
    const latest = await getLatestSnapshot(serviceRole);
    const latestAt = latest?.created_at ? Date.parse(latest.created_at) : 0;
    if (latestAt && Date.now() - latestAt < 15 * 60 * 1000) {
      return res.status(200).json(receipt('already_current', latest));
    }

    const vault = await getLatestVaultRow(serviceRole);
    if (!vault?.channel_id) throw new Error('YouTube token vault is empty');

    const key = deriveEncryptionKey(clientSecret);
    let accessToken = decryptValue(vault.access_token_ciphertext, vault.access_token_iv, vault.access_token_tag, key);
    const refreshToken = vault.refresh_token_ciphertext
      ? decryptValue(vault.refresh_token_ciphertext, vault.refresh_token_iv, vault.refresh_token_tag, key)
      : null;

    if (!vault.access_expires_at || Date.now() >= Date.parse(vault.access_expires_at) - 60_000) {
      if (!refreshToken) throw new Error('Persisted YouTube access token expired and no refresh token is available');
      const refreshed = await refreshAccessToken({ refreshToken, clientId, clientSecret });
      accessToken = refreshed.access_token;
    }

    const inventory = await readInventory(accessToken);
    if (String(inventory.channel.id) !== String(vault.channel_id)) {
      throw new Error('YouTube channel verification mismatch');
    }

    const snapshot = await persistSnapshot(serviceRole, inventory);
    console.info(`[youtube-inventory] status=verified channel=${inventory.channel.id} videos=${inventory.videos.length} playlists=${inventory.playlists.length}`);
    return res.status(200).json(receipt('verified', snapshot));
  } catch (error) {
    const message = sanitizeError(error?.message || error);
    console.error(`[youtube-inventory] status=failed error=${message}`);
    return res.status(502).json({
      schema: 'nexo.youtube.inventory.receipt.v1',
      status: 'failed',
      error: message,
    });
  }
}

async function readInventory(accessToken) {
  const channelItems = await youtubeList('channels', {
    part: 'id,snippet,brandingSettings,contentDetails,statistics,status',
    mine: 'true',
    maxResults: '1',
  }, accessToken);
  const rawChannel = channelItems[0];
  if (!rawChannel?.id) throw new Error('No YouTube channel returned for the persisted account');

  const uploadsPlaylistId = rawChannel?.contentDetails?.relatedPlaylists?.uploads || null;
  const uploadItems = uploadsPlaylistId
    ? await youtubeList('playlistItems', { part: 'id,snippet,contentDetails,status', playlistId: uploadsPlaylistId, maxResults: '50' }, accessToken)
    : [];
  const videoIds = [...new Set(uploadItems.map((item) => item?.contentDetails?.videoId).filter(Boolean))];
  const videos = [];
  for (let i = 0; i < videoIds.length; i += 50) {
    videos.push(...await youtubeList('videos', {
      part: 'id,snippet,contentDetails,statistics,status',
      id: videoIds.slice(i, i + 50).join(','),
      maxResults: '50',
    }, accessToken));
  }

  const playlists = await youtubeList('playlists', {
    part: 'id,snippet,contentDetails,status,player,localizations',
    mine: 'true',
    maxResults: '50',
  }, accessToken);
  const sections = await youtubeList('channelSections', {
    part: 'id,snippet,contentDetails',
    mine: 'true',
  }, accessToken);

  return {
    schema: 'nexo.youtube.channel.inventory.v1',
    checkedAt: new Date().toISOString(),
    channel: sanitizeChannel(rawChannel),
    videos: videos.map(sanitizeVideo),
    playlists: playlists.map(sanitizePlaylist),
    channelSections: sections.map(sanitizeSection),
    limitations: [
      'YouTube Data API does not expose every YouTube Studio setting.',
      'Channel watermark state and all profile links require visual Studio verification.',
      'No content was uploaded, modified, hidden, or deleted by this inventory run.',
    ],
  };
}

async function youtubeList(resource, params, accessToken) {
  const items = [];
  let pageToken = null;
  do {
    const url = new URL(`https://www.googleapis.com/youtube/v3/${resource}`);
    for (const [key, value] of Object.entries(params)) if (value != null) url.searchParams.set(key, String(value));
    if (pageToken) url.searchParams.set('pageToken', pageToken);
    const response = await fetch(url, {
      headers: { Authorization: `Bearer ${accessToken}`, Accept: 'application/json' },
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(`YouTube ${resource} lookup: ${data?.error?.message || `HTTP ${response.status}`}`);
    items.push(...(Array.isArray(data.items) ? data.items : []));
    pageToken = data.nextPageToken || null;
  } while (pageToken);
  return items;
}

function sanitizeChannel(channel) {
  return {
    id: channel.id,
    title: channel?.snippet?.title || null,
    handle: channel?.snippet?.customUrl || null,
    description: channel?.snippet?.description || '',
    publishedAt: channel?.snippet?.publishedAt || null,
    country: channel?.snippet?.country || null,
    defaultLanguage: channel?.snippet?.defaultLanguage || null,
    thumbnails: channel?.snippet?.thumbnails || {},
    brandingSettings: channel?.brandingSettings || {},
    statistics: channel?.statistics || {},
    status: channel?.status || {},
    relatedPlaylists: channel?.contentDetails?.relatedPlaylists || {},
  };
}

function sanitizeVideo(video) {
  return {
    id: video.id,
    title: video?.snippet?.title || null,
    description: video?.snippet?.description || '',
    publishedAt: video?.snippet?.publishedAt || null,
    channelTitle: video?.snippet?.channelTitle || null,
    tags: video?.snippet?.tags || [],
    categoryId: video?.snippet?.categoryId || null,
    defaultLanguage: video?.snippet?.defaultLanguage || null,
    defaultAudioLanguage: video?.snippet?.defaultAudioLanguage || null,
    thumbnails: video?.snippet?.thumbnails || {},
    duration: video?.contentDetails?.duration || null,
    definition: video?.contentDetails?.definition || null,
    caption: video?.contentDetails?.caption || null,
    privacyStatus: video?.status?.privacyStatus || null,
    uploadStatus: video?.status?.uploadStatus || null,
    embeddable: video?.status?.embeddable ?? null,
    madeForKids: video?.status?.madeForKids ?? null,
    statistics: video?.statistics || {},
  };
}

function sanitizePlaylist(playlist) {
  return {
    id: playlist.id,
    title: playlist?.snippet?.title || null,
    description: playlist?.snippet?.description || '',
    publishedAt: playlist?.snippet?.publishedAt || null,
    privacyStatus: playlist?.status?.privacyStatus || null,
    itemCount: playlist?.contentDetails?.itemCount ?? null,
    thumbnails: playlist?.snippet?.thumbnails || {},
  };
}

function sanitizeSection(section) {
  return {
    id: section.id,
    type: section?.snippet?.type || null,
    style: section?.snippet?.style || null,
    title: section?.snippet?.title || null,
    position: section?.snippet?.position ?? null,
    playlists: section?.contentDetails?.playlists || [],
    channels: section?.contentDetails?.channels || [],
  };
}

async function getLatestVaultRow(serviceRole) {
  const fields = [
    'channel_id','channel_title','scopes','access_token_ciphertext','access_token_iv','access_token_tag',
    'refresh_token_ciphertext','refresh_token_iv','refresh_token_tag','access_expires_at','updated_at',
  ].join(',');
  const url = `${SUPABASE_URL}/rest/v1/youtube_oauth_token_vault?select=${encodeURIComponent(fields)}&order=updated_at.desc&limit=1`;
  const rows = await supabaseRequest(url, serviceRole);
  return rows?.[0] || null;
}

async function getLatestSnapshot(serviceRole) {
  const url = `${SUPABASE_URL}/rest/v1/director_external_evidence?select=id,created_at,status,evidence&project_key=eq.${PROJECT_KEY}&task_key=eq.${TASK_KEY}&order=created_at.desc&limit=1`;
  const rows = await supabaseRequest(url, serviceRole);
  return rows?.[0] || null;
}

async function persistSnapshot(serviceRole, inventory) {
  const response = await fetch(`${SUPABASE_URL}/rest/v1/director_external_evidence`, {
    method: 'POST',
    headers: {
      apikey: serviceRole,
      Authorization: `Bearer ${serviceRole}`,
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    },
    body: JSON.stringify({
      project_key: PROJECT_KEY,
      task_key: TASK_KEY,
      evidence_type: 'youtube_api_inventory',
      environment: 'production',
      engine: 'youtube-data-api-v3',
      version: 'v1',
      status: 'pass',
      evidence: inventory,
      source: 'nexo.youtube.inventory.v1',
      verified: true,
    }),
  });
  const rows = await response.json().catch(() => []);
  if (!response.ok) throw new Error(`YouTube inventory persistence failed: HTTP ${response.status}`);
  return rows?.[0] || null;
}

async function supabaseRequest(url, serviceRole) {
  const response = await fetch(url, {
    headers: { apikey: serviceRole, Authorization: `Bearer ${serviceRole}`, Accept: 'application/json' },
  });
  const data = await response.json().catch(() => []);
  if (!response.ok) throw new Error(`Supabase inventory lookup failed: HTTP ${response.status}`);
  return data;
}

async function refreshAccessToken({ refreshToken, clientId, clientSecret }) {
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

function deriveEncryptionKey(clientSecret) {
  const material = process.env.YOUTUBE_TOKEN_ENCRYPTION_KEY || clientSecret;
  return crypto.createHash('sha256').update(`contentflow-youtube-token-v1:${material}`).digest();
}

function decryptValue(ciphertext, iv, tag, key) {
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(iv, 'base64'));
  decipher.setAuthTag(Buffer.from(tag, 'base64'));
  return Buffer.concat([decipher.update(Buffer.from(ciphertext, 'base64')), decipher.final()]).toString('utf8');
}

function receipt(status, snapshot) {
  const evidence = snapshot?.evidence || {};
  return {
    schema: 'nexo.youtube.inventory.receipt.v1',
    status,
    evidenceId: snapshot?.id || null,
    channelId: evidence?.channel?.id || null,
    channelTitle: evidence?.channel?.title || null,
    videoCount: Array.isArray(evidence?.videos) ? evidence.videos.length : null,
    playlistCount: Array.isArray(evidence?.playlists) ? evidence.playlists.length : null,
    checkedAt: evidence?.checkedAt || snapshot?.created_at || new Date().toISOString(),
    secretsExposed: false,
  };
}

function sanitizeError(value) {
  return String(value)
    .replace(/(access_token|refresh_token|client_secret)=[^&\s]+/gi, '$1=[redacted]')
    .replace(/ya29\.[A-Za-z0-9._-]+/g, '[redacted-token]')
    .slice(0, 500);
}
