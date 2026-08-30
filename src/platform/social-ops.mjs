import fs from 'node:fs/promises';
import path from 'node:path';
import crypto from 'node:crypto';

const SUPPORTED = new Set(['facebook','instagram','tiktok','youtube']);

function normalize(input = {}) {
  const id = input.id ?? crypto.randomUUID();
  const platform = String(input.platform ?? '').toLowerCase();
  if (!SUPPORTED.has(platform)) throw new Error('social_ops_unsupported_platform');
  const action = input.action ?? 'inspect';
  if (!['inspect','prepare_publish','publish'].includes(action)) throw new Error('social_ops_invalid_action');
  if (action === 'publish' && input.approved !== true) throw new Error('social_ops_approval_required');
  return {
    id,
    platform,
    action,
    approved: input.approved === true,
    targetUrl: input.targetUrl ?? null,
    text: input.text ?? '',
    media: Array.isArray(input.media) ? input.media : [],
    source: input.source ?? 'director',
    evidenceDir: input.evidenceDir ?? 'certification-evidence/social-ops',
  };
}

export async function createSocialOpsReceipt(input = {}) {
  const task = normalize(input);
  const dir = path.resolve(task.evidenceDir, task.id);
  await fs.mkdir(dir, { recursive: true });
  const receipt = {
    schema: 'cygnus.social.ops.v1',
    taskId: task.id,
    platform: task.platform,
    action: task.action,
    approved: task.approved,
    source: task.source,
    targetUrl: task.targetUrl,
    textLength: task.text.length,
    mediaCount: task.media.length,
    status: task.action === 'publish' ? 'ready_for_browser_or_api_execution' : 'prepared',
    executionPolicy: {
      requireExplicitApprovalForPublish: true,
      preserveAuthenticatedSession: true,
      captureEvidence: true,
      neverStorePlaintextPasswords: true,
      preferOfficialApiWhenAvailable: true,
      browserFallback: true
    },
    createdAt: new Date().toISOString()
  };
  const receiptPath = path.join(dir, 'receipt.json');
  await fs.writeFile(receiptPath, JSON.stringify(receipt, null, 2));
  return { ...receipt, receiptPath };
}

if (import.meta.url === `file://${process.argv[1]}`) {
  const platform = process.argv[2] ?? process.env.SOCIAL_PLATFORM ?? 'facebook';
  const action = process.argv[3] ?? process.env.SOCIAL_ACTION ?? 'inspect';
  const approved = process.env.SOCIAL_APPROVED === '1';
  const receipt = await createSocialOpsReceipt({ platform, action, approved });
  process.stdout.write(`${JSON.stringify(receipt, null, 2)}\n`);
}
