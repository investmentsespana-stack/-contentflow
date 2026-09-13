import crypto from 'node:crypto';

const PREFLIGHT_VIDEO_SIZE = 1024 * 1024;

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'application/json; charset=utf-8');
  if (req.method !== 'POST') return res.status(405).json({ error: 'Method Not Allowed' });

  const { clientSecret, mode } = getRuntime();
  if (!clientSecret) return res.status(503).json({ error: `TikTok ${mode} runtime credentials are not configured.` });

  const cookies = parseCookies(req.headers.cookie || '');
  if (!cookies.tiktok_demo_session) return res.status(401).json({ error: 'TikTok demo session is not connected.' });

  let session;
  try {
    session = decryptSession(cookies.tiktok_demo_session, clientSecret);
  } catch {
    return res.status(401).json({ error: 'TikTok demo session is invalid.' });
  }

  if (session?.mode && session.mode !== mode) {
    return res.status(401).json({ error: 'TikTok demo session mode does not match runtime mode.' });
  }
  if (!session?.access_token || Date.now() >= Number(session.expires_at || 0)) {
    return res.status(401).json({ error: 'TikTok access token expired. Reconnect through Login Kit.' });
  }
  if (!Array.isArray(session.scope) || !session.scope.includes('video.upload')) {
    return res.status(403).json({ error: 'video.upload scope was not granted.' });
  }

  try {
    const initResponse = await fetch('https://open.tiktokapis.com/v2/post/publish/inbox/video/init/', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${session.access_token}`,
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: JSON.stringify({
        source_info: {
          source: 'FILE_UPLOAD',
          video_size: PREFLIGHT_VIDEO_SIZE,
          chunk_size: PREFLIGHT_VIDEO_SIZE,
          total_chunk_count: 1,
        },
      }),
    });
    const initData = await initResponse.json().catch(() => ({}));
    if (!initResponse.ok || initData?.error?.code && initData.error.code !== 'ok' || !initData?.data?.upload_url) {
      throw new Error(`TikTok upload init: ${initData?.error?.message || initData?.error?.code || `HTTP ${initResponse.status}`}`);
    }

    const receipt = {
      schema: 'nexo.tiktok.content_posting.preflight.v1',
      status: 'upload_session_initialized',
      mode,
      identity: session.open_id ? 'oauth_identity_bound' : 'oauth_identity_missing',
      scopes: session.scope,
      publishId: initData.data.publish_id || null,
      contentBytesUploaded: 0,
      publicPostsCreated: 0,
      checkedAt: new Date().toISOString(),
      note: 'TikTok accepted an upload-session initialization. No media bytes were uploaded and no post was created.',
    };
    console.info(`[tiktok-preflight] status=${receipt.status} mode=${mode} bytes=0 publish_id=${receipt.publishId || 'none'}`);
    return res.status(200).json(receipt);
  } catch (err) {
    const safe = sanitizeError(err?.message || err);
    console.error(`[tiktok-preflight] mode=${mode} ${safe}`);
    return res.status(502).json({ error: safe, contentBytesUploaded: 0, publicPostsCreated: 0 });
  }
}

function getRuntime() {
  const requestedMode = String(process.env.TIKTOK_OAUTH_MODE || 'production').toLowerCase();
  const mode = requestedMode === 'sandbox' ? 'sandbox' : 'production';
  return {
    mode,
    clientSecret: mode === 'sandbox'
      ? process.env.TIKTOK_SANDBOX_CLIENT_SECRET
      : process.env.TIKTOK_CLIENT_SECRET,
  };
}

function decryptSession(value, secret) {
  const [ivB64, tagB64, cipherB64] = String(value).split('.', 3);
  if (!ivB64 || !tagB64 || !cipherB64) throw new Error('Malformed session.');
  const key = crypto.createHash('sha256').update(`contentflow-tiktok-demo-v1:${secret}`).digest();
  const decipher = crypto.createDecipheriv('aes-256-gcm', key, Buffer.from(ivB64, 'base64url'));
  decipher.setAuthTag(Buffer.from(tagB64, 'base64url'));
  const plain = Buffer.concat([decipher.update(Buffer.from(cipherB64, 'base64url')), decipher.final()]);
  return JSON.parse(plain.toString('utf8'));
}

function parseCookies(header) {
  return header.split(';').reduce((acc, item) => {
    const index = item.indexOf('=');
    if (index > -1) acc[item.slice(0, index).trim()] = item.slice(index + 1).trim();
    return acc;
  }, {});
}

function sanitizeError(value) {
  return String(value)
    .replace(/(?:act|rft)\.[A-Za-z0-9._-]+/g, '[redacted-token]')
    .replace(/https:\/\/open-upload\.tiktokapis\.com\/[^\s]+/gi, '[redacted-upload-url]')
    .slice(0, 500);
}
