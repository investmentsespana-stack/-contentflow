import crypto from 'node:crypto';

const APP_ID = process.env.META_APP_ID || '1784797469372306';
const REDIRECT_URI = process.env.META_OAUTH_REDIRECT_URI || 'https://contentflow-ai-tan.vercel.app/api/meta/oauth/callback';
const GRAPH_VERSION = process.env.META_GRAPH_VERSION || 'v23.0';
const EXPECTED_PAGE_ID = process.env.META_PAGE_ID || '102575905973808';
const EXPECTED_INSTAGRAM_ID = process.env.META_INSTAGRAM_ID || '17841455070447156';
const SUPABASE_URL = process.env.SUPABASE_URL || 'https://koqpyfvnprmirqviafzq.supabase.co';

export default async function handler(req, res) {
  res.setHeader('Cache-Control', 'no-store');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');

  if (req.method !== 'GET') return res.status(405).send('Method Not Allowed');

  const { code, state, error, error_description: errorDescription } = req.query || {};
  if (error) {
    console.warn(`[meta-oauth] preflight=meta_authorization_not_completed error=${sanitizeError(error)} description=${sanitizeError(errorDescription || '')}`);
    return res.status(400).send(page('Meta authorization not completed', escapeHtml(errorDescription || error)));
  }
  if (!code) {
    console.warn('[meta-oauth] preflight=missing_authorization_code');
    return res.status(400).send(page('Missing authorization code', 'Return to the Meta authorization flow and try again.'));
  }

  const appSecret = process.env.META_APP_SECRET;
  if (!appSecret) {
    console.error('[meta-oauth] preflight=meta_app_secret_missing');
    return res.status(503).send(page('Runtime configuration incomplete', 'META_APP_SECRET is not configured.'));
  }
  if (!validateState(state, appSecret)) {
    console.warn(`[meta-oauth] preflight=invalid_or_expired_state state_present=${Boolean(state)}`);
    return res.status(400).send(page('Invalid or expired OAuth state', 'Start the authorization flow again from ContentFlow.'));
  }

  let stage = 'exchange_code';
  try {
    const shortToken = await exchangeCode(code, appSecret);

    stage = 'exchange_long_lived_token';
    const userToken = await exchangeLongLived(shortToken, appSecret).catch(() => shortToken);

    stage = 'read_user_permissions_and_pages';
    const [me, permissions, accounts] = await Promise.all([
      graphGet('/me', userToken, { fields: 'id,name' }),
      graphGet('/me/permissions', userToken),
      graphGet('/me/accounts', userToken, { fields: 'id,name,tasks,access_token' }),
    ]);

    const grantedScopes = (permissions.data || [])
      .filter((p) => p.status === 'granted')
      .map((p) => p.permission)
      .sort();

    stage = 'select_expected_page';
    let pageAsset = (accounts.data || []).find((item) => String(item.id) === EXPECTED_PAGE_ID) || null;

    // New Pages Experience / Business Portfolio setups can occasionally omit an
    // otherwise authorized Page from /me/accounts. Safely try the exact expected
    // Page with the same user token before declaring the asset unauthorized.
    if (!pageAsset?.access_token) {
      stage = 'direct_expected_page_lookup';
      try {
        const directPage = await graphGet(`/${EXPECTED_PAGE_ID}`, userToken, {
          fields: 'id,name,tasks,access_token,instagram_business_account{id,username}',
        });
        if (String(directPage?.id || '') === EXPECTED_PAGE_ID && directPage?.access_token) {
          pageAsset = directPage;
          console.info(`[meta-oauth] expected_page_source=direct_lookup page=${EXPECTED_PAGE_ID}`);
        }
      } catch (lookupErr) {
        console.warn(`[meta-oauth] expected_page_direct_lookup_failed error=${sanitizeError(lookupErr?.message || 'Unknown error')}`);
      }
    }

    if (!pageAsset?.access_token) {
      const returnedPageIds = (accounts.data || []).map((item) => String(item.id || '')).filter(Boolean).slice(0, 25);
      console.warn(`[meta-oauth] expected_page_missing expected=${EXPECTED_PAGE_ID} returned_pages=${returnedPageIds.join(',') || 'none'} granted_scopes=${grantedScopes.join(',') || 'none'}`);
      return res.status(403).send(page(
        'Cygnus page not authorized',
        `Expected Page ${EXPECTED_PAGE_ID} was not returned by Meta and direct verification did not produce a Page token. No token was persisted.`
      ));
    }

    stage = 'verify_instagram_asset';
    let instagram = pageAsset.instagram_business_account || null;
    if (!instagram) {
      const igInfo = await graphGet(`/${EXPECTED_PAGE_ID}`, pageAsset.access_token, {
        fields: 'instagram_business_account{id,username}',
      });
      instagram = igInfo.instagram_business_account || null;
    }
    if (!instagram || String(instagram.id) !== EXPECTED_INSTAGRAM_ID) {
      console.warn(`[meta-oauth] instagram_mismatch expected=${EXPECTED_INSTAGRAM_ID} actual=${instagram?.id || 'none'}`);
      return res.status(403).send(page('Instagram asset mismatch', `Expected Instagram ${EXPECTED_INSTAGRAM_ID} was not returned by Meta. No token was persisted.`));
    }

    const tasks = Array.isArray(pageAsset.tasks) ? pageAsset.tasks : [];
    const fingerprint = crypto.createHash('sha256').update(pageAsset.access_token).digest('hex').slice(0, 16);

    stage = 'persist_encrypted_page_token';
    const persistence = await persistEncryptedPageToken({
      appSecret,
      userId: String(me.id || ''),
      pageId: EXPECTED_PAGE_ID,
      instagramId: EXPECTED_INSTAGRAM_ID,
      scopes: grantedScopes,
      tasks,
      token: pageAsset.access_token,
      fingerprint,
    });

    const receipt = {
      schema: 'nexo.meta.oauth.connection.v1',
      status: persistence.persisted ? 'connected_persisted' : 'connected_not_persisted',
      appId: APP_ID,
      page: { id: EXPECTED_PAGE_ID, name: pageAsset.name || null },
      instagram: { id: String(instagram.id), username: instagram.username || null },
      scopes: grantedScopes,
      tasks,
      tokenFingerprint: fingerprint,
      tokenPersisted: persistence.persisted,
      persistenceReason: persistence.reason || null,
      checkedAt: new Date().toISOString(),
    };

    console.info(`[meta-oauth] status=${receipt.status} page=${EXPECTED_PAGE_ID} instagram=${EXPECTED_INSTAGRAM_ID} persisted=${receipt.tokenPersisted}`);
    return res.status(persistence.persisted ? 200 : 206).send(page(
      persistence.persisted ? 'Meta OAuth connected' : 'Meta OAuth verified; vault pending',
      `<pre>${escapeHtml(JSON.stringify(receipt, null, 2))}</pre>`,
    ));
  } catch (err) {
    const safeMessage = sanitizeError(err?.message || 'Unknown error');
    console.error(`[meta-oauth] stage=${stage} error=${safeMessage}`);
    return res.status(502).send(page('Meta OAuth verification failed', `${escapeHtml(stage)}: ${escapeHtml(safeMessage)}`));
  }
}

async function exchangeCode(code, appSecret) {
  const url = new URL(`https://graph.facebook.com/${GRAPH_VERSION}/oauth/access_token`);
  url.searchParams.set('client_id', APP_ID);
  url.searchParams.set('client_secret', appSecret);
  url.searchParams.set('redirect_uri', REDIRECT_URI);
  url.searchParams.set('code', String(code));
  const data = await fetchJson(url);
  if (!data.access_token) throw new Error('Meta did not return an access token.');
  return data.access_token;
}

async function exchangeLongLived(token, appSecret) {
  const url = new URL(`https://graph.facebook.com/${GRAPH_VERSION}/oauth/access_token`);
  url.searchParams.set('grant_type', 'fb_exchange_token');
  url.searchParams.set('client_id', APP_ID);
  url.searchParams.set('client_secret', appSecret);
  url.searchParams.set('fb_exchange_token', token);
  const data = await fetchJson(url);
  if (!data.access_token) throw new Error('Long-lived token exchange failed.');
  return data.access_token;
}

async function graphGet(path, token, params = {}) {
  const url = new URL(`https://graph.facebook.com/${GRAPH_VERSION}${path}`);
  for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
  url.searchParams.set('access_token', token);
  return fetchJson(url);
}

async function fetchJson(url) {
  const response = await fetch(url, { headers: { Accept: 'application/json' } });
  const data = await response.json().catch(() => ({}));
  if (!response.ok || data.error) {
    const message = data?.error?.message || `HTTP ${response.status}`;
    throw new Error(`Meta API: ${message}`);
  }
  return data;
}

function validateState(state, appSecret) {
  if (!state || typeof state !== 'string' || !state.includes('.')) return false;
  const [payload, signature] = state.split('.', 2);
  const expected = signState(payload, appSecret);
  try {
    const a = Buffer.from(signature, 'base64url');
    const b = Buffer.from(expected, 'base64url');
    if (a.length !== b.length || !crypto.timingSafeEqual(a, b)) return false;
    const parsed = JSON.parse(Buffer.from(payload, 'base64url').toString('utf8'));
    return Number.isFinite(parsed.iat) && Date.now() - parsed.iat >= 0 && Date.now() - parsed.iat <= 10 * 60 * 1000;
  } catch {
    return false;
  }
}

function signState(payload, appSecret) {
  return crypto.createHmac('sha256', `contentflow-meta-state:${appSecret}`)
    .update(payload)
    .digest('base64url');
}

async function persistEncryptedPageToken({ appSecret, userId, pageId, instagramId, scopes, tasks, token, fingerprint }) {
  const serviceRole = process.env.SUPABASE_SERVICE_ROLE_KEY;
  if (!serviceRole) return { persisted: false, reason: 'SUPABASE_SERVICE_ROLE_KEY missing in runtime' };

  const key = deriveEncryptionKey(appSecret);
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ciphertext = Buffer.concat([cipher.update(token, 'utf8'), cipher.final()]);
  const tag = cipher.getAuthTag();

  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/upsert_meta_oauth_token`, {
    method: 'POST',
    headers: {
      apikey: serviceRole,
      Authorization: `Bearer ${serviceRole}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({
      p_app_id: APP_ID,
      p_user_id: userId || null,
      p_page_id: pageId,
      p_instagram_id: instagramId,
      p_scopes: scopes,
      p_tasks: tasks,
      p_token_ciphertext: ciphertext.toString('base64'),
      p_token_iv: iv.toString('base64'),
      p_token_tag: tag.toString('base64'),
      p_token_fingerprint: fingerprint,
      p_expires_at: null,
    }),
  });

  if (!response.ok) {
    const body = await response.text().catch(() => '');
    throw new Error(`Token vault persistence failed: HTTP ${response.status}${body ? ` ${body.slice(0, 160)}` : ''}`);
  }
  return { persisted: true };
}

function deriveEncryptionKey(appSecret) {
  return crypto.createHash('sha256')
    .update(`contentflow-meta-token-v1:${appSecret}`)
    .digest();
}

function sanitizeError(value) {
  return String(value)
    .replace(/EA[A-Za-z0-9_-]{20,}/g, '[redacted-token]')
    .replace(/access_token=[^&\s]+/gi, 'access_token=[redacted]')
    .slice(0, 500);
}

function page(title, body) {
  return `<!doctype html><html><head><meta charset="utf-8"><meta name="robots" content="noindex,nofollow"><title>${escapeHtml(title)}</title></head><body><h1>${escapeHtml(title)}</h1><div>${body}</div><p>No access token is displayed on this page.</p></body></html>`;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#039;');
}
