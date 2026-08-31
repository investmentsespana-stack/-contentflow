const TARGET_CHANNEL_ID = 'UCZhxLanR9eh7u2PtMv9Bxjg';

export function buildYouTubeManagementPreflight(input = {}) {
  const channelId = String(input.channelId || '');
  const scopes = new Set(Array.isArray(input.scopes) ? input.scopes : []);
  const sameChannel = channelId === TARGET_CHANNEL_ID;
  const hasManage = scopes.has('https://www.googleapis.com/auth/youtube');
  const hasUpload = scopes.has('https://www.googleapis.com/auth/youtube.upload');
  return {
    schema: 'nexo.youtube.management.preflight.v1',
    status: sameChannel && hasManage ? 'ready_for_reversible_management' : 'blocked',
    channelId: channelId || null,
    expectedChannelId: TARGET_CHANNEL_ID,
    sameChannel,
    capabilities: {
      inventory: sameChannel,
      reversibleApiManagement: sameChannel && hasManage,
      uploadPrivate: sameChannel && hasUpload,
      publicPublish: false,
      permanentDelete: false,
      handleMutation: false,
      studioIdentityMutation: false,
    },
    gates: {
      handle: 'studio_authoritative',
      publicNameAvatarLinks: 'authenticated_studio_or_certified_adapter_required',
      upload: 'separate_human_approval_required',
      publication: 'separate_human_approval_required',
    },
    mode: 'no_mutation',
    checkedAt: new Date().toISOString(),
  };
}
