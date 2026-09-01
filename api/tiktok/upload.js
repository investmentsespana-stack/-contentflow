import crypto from 'node:crypto';

export const config = { api: { bodyParser: false } };

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

  const declaredSize = Number(req.headers['x-video-size'] || 0);
  if (!Number.isFinite(declaredSize) || declaredSize <= 0 || declaredSize > 4 * 1024 * 1024) {
    return res.status(400).json({ error: 'Use a demo video between 1 byte and 4 MB.' });
  }

  try {
    const video = await readBody(req, declaredSize);
    if (video.length !== declaredSize) return res.status(400).json({ error: 'Video size mismatch.' });

    const initResponse = await fetch('https://open.tiktokapis.com/v2/post/publish/inbox/video/init/', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${session.access_token}`,
        'Content-Type': 'application/json; charset=UTF-8',
      },
      body: JSON.stringify({
        source_info: {
          source: 'FILE_UPLOAD',
          video_size: video.length,
          chunk_size: video.length,
          total_chunk_count: 1,
        },
      }),
    });
    const initData = await initResponse.json().catch(() => ({}));
    if (!initResponse.ok || initData?.error?.code && initData.error.code !== 'ok' || !initData?.data?.upload_url) {
      throw new Error(`TikTok upload init: ${initData?.error?.message || initData?.error?.code || `HTTP ${initResponse.status}`}`);
    }

    const uploadResponse = await fetch(initData.data.upload_url, {
      method: 'PUT',
      headers: {
        'Content-Type': req.headers['content-type'] || 'video/mp4',
        'Content-Length': String(video.length),
        'Content-Range': `bytes 0-${video.length - 1}/${video.length}`,
      },
      body: video,
    });
    if (!uploadResponse.ok) throw new Error(`TikTok binary upload: HTTP ${uploadResponse.status}`);

    const receipt = {
      schema: 'nexo.tiktok.content_posting.demo.v1',
      status: 'uploaded_to_tiktok_inbox',
      publishId: initData.data.publish_id || null,
      openId: session.open_id || null,
      scopes: session.scope,
      uploadedBytes: video.length,
      checkedAt: new Date().toISOString(),
      nextAction: 'Open TikTok inbox notification to continue editing and complete the post.',
    };
    console.info(`[tiktok-upload] status=${receipt.status} mode=${mode} bytes=${video.length} publish_id=${receipt.publishId || 'none'}`);
    return res.status(200).json(receipt);
  } catch (err) {
    const safe = sanitizeError(err?.message || err);
    console.error(`[tiktok-upload] mode=${mode} ${safe}`);
    return res.status(502).json({ error: safe });
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

async function readBody(req, expectedSize) {
  const chunks = [];
  let total = 0;
  for await (const chunk of req) {
    total += chunk.length;
    if (total > expectedSize || total > 4 * 1024 * 1024) throw new Error('Request body exceeds demo size limit.');
    chunks.push(chunk);
  }
  return Buffer.concat(chunks);
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
