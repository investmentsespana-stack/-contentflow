import { verifyMetaPagesConnection } from './meta-pages-connector.mjs';

const REQUIRED_FB_PERMISSIONS = ['pages_show_list','pages_read_engagement','pages_manage_posts'];
const REQUIRED_IG_PERMISSIONS = ['instagram_basic','instagram_content_publish'];

async function graphGet(pathname, params, { accessToken, graphVersion, fetchImpl = fetch, graphOrigin = 'https://graph.facebook.com' }) {
  const url = new URL(`${graphOrigin}/${graphVersion}/${pathname.replace(/^\//,'')}`);
  for (const [k,v] of Object.entries(params || {})) if (v != null) url.searchParams.set(k, String(v));
  url.searchParams.set('access_token', accessToken);
  const response = await fetchImpl(url, { headers: { accept: 'application/json' } });
  const body = await response.json().catch(() => ({}));
  if (!response.ok || body?.error) throw new Error(`meta_graph_error:${body?.error?.type || 'graph_error'}:${body?.error?.code || response.status}`);
  return body;
}

export async function verifyMetaWritePreflight(input = {}, deps = {}) {
  const accessToken = input.userAccessToken ?? process.env.META_USER_ACCESS_TOKEN;
  const graphVersion = input.graphVersion ?? process.env.META_GRAPH_VERSION;
  if (!accessToken) throw new Error('meta_write_user_access_token_required');
  if (!graphVersion) throw new Error('meta_write_graph_version_required');

  const base = await verifyMetaPagesConnection(input, deps);
  const permsRaw = await graphGet('me/permissions', {}, { ...deps, accessToken, graphVersion });
  const granted = new Set((permsRaw.data || []).filter(p => p.status === 'granted').map(p => p.permission));

  const fbMissing = REQUIRED_FB_PERMISSIONS.filter(p => !granted.has(p));
  let instagram = null;
  if (base.page?.id && base.page?.hasPageAccessToken) {
    const accounts = await graphGet('me/accounts', { fields: 'id,access_token' }, { ...deps, accessToken, graphVersion });
    const selected = (accounts.data || []).find(p => String(p.id) === String(base.page.id));
    if (selected?.access_token) {
      const page = await graphGet(String(base.page.id), { fields: 'instagram_business_account{id,username}' }, { ...deps, accessToken: selected.access_token, graphVersion });
      instagram = page.instagram_business_account || null;
    }
  }

  const igMissing = REQUIRED_IG_PERMISSIONS.filter(p => !granted.has(p));
  const pageTasks = new Set(base.page?.tasks || []);
  const taskSupportsContent = pageTasks.has('CREATE_CONTENT') || pageTasks.has('MANAGE');

  return {
    schema: 'nexo.meta.write.preflight.v1',
    status: base.page && base.page.hasPageAccessToken && fbMissing.length === 0 && taskSupportsContent ? 'facebook_write_preflight_pass' : 'partial',
    facebook: {
      pageId: base.page?.id || null,
      pageName: base.page?.name || null,
      hasPageAccessToken: Boolean(base.page?.hasPageAccessToken),
      contentTaskPresent: taskSupportsContent,
      missingPermissions: fbMissing,
    },
    instagram: {
      accountId: instagram?.id || null,
      username: instagram?.username || null,
      linkedBusinessAccountPresent: Boolean(instagram?.id),
      missingPermissions: igMissing,
      writePreflightPass: Boolean(instagram?.id) && igMissing.length === 0,
    },
    mode: 'read_only_write_capability_preflight',
    checkedAt: new Date().toISOString(),
  };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const receipt = await verifyMetaWritePreflight({
    pageId: process.env.META_PAGE_ID ?? null,
    pageName: process.env.META_PAGE_NAME ?? null,
    graphVersion: process.env.META_GRAPH_VERSION ?? null,
  });
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
}
