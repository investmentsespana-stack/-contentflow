import crypto from 'node:crypto';

const DEFAULT_GRAPH_VERSION = process.env.META_GRAPH_VERSION || 'v23.0';
const DEFAULT_GRAPH_ORIGIN = 'https://graph.facebook.com';

function required(value, name) {
  if (!value) throw new Error(`meta_pages_${name}_required`);
  return value;
}

function redactToken(value) {
  if (!value) return null;
  return `sha256:${crypto.createHash('sha256').update(value).digest('hex').slice(0, 16)}`;
}

async function graphGet(pathname, params, options) {
  const fetchImpl = options.fetchImpl ?? fetch;
  const graphOrigin = options.graphOrigin ?? DEFAULT_GRAPH_ORIGIN;
  const graphVersion = options.graphVersion ?? DEFAULT_GRAPH_VERSION;
  const accessToken = required(options.accessToken, 'access_token');
  const url = new URL(`${graphOrigin}/${graphVersion}/${pathname.replace(/^\//, '')}`);
  for (const [key, value] of Object.entries(params ?? {})) {
    if (value !== undefined && value !== null) url.searchParams.set(key, String(value));
  }
  url.searchParams.set('access_token', accessToken);

  const response = await fetchImpl(url, { method: 'GET', headers: { accept: 'application/json' } });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || body?.error) {
    const code = body?.error?.code ?? response.status;
    const type = body?.error?.type ?? 'graph_error';
    throw new Error(`meta_pages_graph_error:${type}:${code}`);
  }
  return body;
}

export async function verifyMetaPagesConnection(input = {}, deps = {}) {
  const userAccessToken = required(input.userAccessToken ?? process.env.META_USER_ACCESS_TOKEN, 'user_access_token');
  const pageName = input.pageName ?? null;
  const pageId = input.pageId ?? process.env.META_PAGE_ID ?? null;
  const graphVersion = input.graphVersion ?? process.env.META_GRAPH_VERSION ?? DEFAULT_GRAPH_VERSION;

  const accounts = await graphGet('me/accounts', { fields: 'id,name,access_token,tasks' }, {
    ...deps,
    accessToken: userAccessToken,
    graphVersion,
  });

  const pages = Array.isArray(accounts.data) ? accounts.data : [];
  let selected = null;
  if (pageId) selected = pages.find((page) => String(page.id) === String(pageId)) ?? null;
  if (!selected && pageName) selected = pages.find((page) => page.name === pageName) ?? null;

  const safePages = pages.map((page) => ({
    id: page.id,
    name: page.name,
    tasks: page.tasks ?? [],
    hasPageAccessToken: Boolean(page.access_token),
  }));

  return {
    schema: 'nexo.meta.pages.connection.v1',
    status: selected ? 'connected' : 'page_not_selected',
    graphVersion,
    page: selected ? {
      id: selected.id,
      name: selected.name,
      tasks: selected.tasks ?? [],
      hasPageAccessToken: Boolean(selected.access_token),
    } : null,
    pages: safePages,
    userTokenFingerprint: redactToken(userAccessToken),
    checkedAt: new Date().toISOString(),
    mode: 'read_only_verification',
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const receipt = await verifyMetaPagesConnection({
    pageId: process.env.META_PAGE_ID ?? null,
    pageName: process.env.META_PAGE_NAME ?? null,
  });
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
}
